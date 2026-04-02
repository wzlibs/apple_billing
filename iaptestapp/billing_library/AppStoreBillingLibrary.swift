import StoreKit
import Foundation

@MainActor
class AppStoreBillingLibrary: BillingLibrary {

    private var purchaseUpdateListener: ((PurchaseUpdate) -> Void)?
    private var transactionObserverTask: Task<Void, Never>?

    private var billingProducts: [String: BillingProduct] = [:]
    private var cachedProducts: [String: Product] = [:]

    /// Transaction IDs processed by `performPurchase` this session.
    /// Used to prevent double-handling when `Transaction.updates` delivers the same transaction.
    private var handledTransactionIDs: Set<UInt64> = []

    private let adjustTracker: AdjustIapTracker?

    init(adjustTracker: AdjustIapTracker? = nil) {
        self.adjustTracker = adjustTracker
    }

    deinit {
        transactionObserverTask?.cancel()
    }

    // MARK: - BillingLibrary

    func setPurchaseUpdateListener(_ listener: ((PurchaseUpdate) -> Void)?) {
        self.purchaseUpdateListener = listener
    }

    /// StoreKit 2 does not require an explicit connection step.
    /// Starts the transaction observer and returns `.connected` immediately.
    func connect() async -> BillingConnectionResult {
        transactionObserverTask = observeTransactionUpdates()
        return .connected
    }

    func queryProductDetailsAndPurchases(
        products: [BillingProduct]
    ) async -> BillingQueryResult {
        products.forEach { billingProducts[$0.productId] = $0 }

        async let productsTask = fetchProducts(ids: products.map { $0.productId })
        async let entitlementsTask = fetchCurrentEntitlements()

        let (skProducts, purchaseRecords) = await (productsTask, entitlementsTask)

        cachedProducts = skProducts
        let billingProductDetails = skProducts.values.map { $0.toBillingProductDetail() }

        print("[BillingLibrary] Mapped \(billingProductDetails.count) BillingProductDetail(s)")
        for detail in billingProductDetails {
            print("[BillingLibrary] BillingProductDetail JSON:\n\(detail.toJSONString())")
        }

        if let tracker = adjustTracker {
            let detailMap = Dictionary(
                uniqueKeysWithValues: billingProductDetails.map { ($0.productId, $0) }
            )
            tracker.trackPurchases(purchases: purchaseRecords, productDetails: detailMap)
        }

        return BillingQueryResult(
            productDetails: Array(billingProductDetails),
            purchaseRecords: purchaseRecords
        )
    }

    func purchase(product: BillingProductDetail) {
        guard let skProduct = cachedProducts[product.productId] else {
            emitUpdate(.error)
            return
        }
        Task { await performPurchase(skProduct: skProduct) }
    }

    /// StoreKit 2 has no explicit disconnect — cancel the observer task.
    func endConnection() {
        transactionObserverTask?.cancel()
        transactionObserverTask = nil
    }

    // MARK: - Private

    private func emitUpdate(_ update: PurchaseUpdate) {
        purchaseUpdateListener?(update)
    }

    /// Listens to `Transaction.updates` for renewals, background purchases, Ask-to-Buy
    /// approvals, and unfinished transactions from previous app sessions.
    ///
    /// Each verified transaction is processed individually — no full re-fetch needed.
    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                await self.handleTransactionUpdate(result)
            }
        }
    }

    /// Processes a single transaction from the update stream.
    private func handleTransactionUpdate(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .unverified:
            // Tampered receipt — do not grant access.
            emitUpdate(.error)

        case .verified(let transaction):
            // Skip transactions already handled by performPurchase this session.
            if handledTransactionIDs.remove(transaction.id) != nil {
                await transaction.finish()
                return
            }

            if transaction.revocationDate != nil {
                // Subscription was revoked (refund / chargeback).
                // Caller should re-check entitlements and remove access.
                emitUpdate(.error)
                return
            }

            let record = transaction.toPurchaseRecord()
            let productDetail = cachedProducts[record.productId]?.toBillingProductDetail()

            adjustTracker?.trackPurchase(purchase: record, billingProductDetail: productDetail)
            await transaction.finish()
            emitUpdate(.succeeded([PurchasedItem(record: record, productDetail: productDetail)]))
        }
    }

    private func fetchProducts(ids: [String]) async -> [String: Product] {
        print("[BillingLibrary] Fetching products for IDs: \(ids)")
        do {
            let products = try await Product.products(for: ids)
            print("[BillingLibrary] Fetched \(products.count) product(s)")
            return Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
        } catch {
            print("[BillingLibrary] fetchProducts ERROR: \(error)")
            return [:]
        }
    }

    private func fetchCurrentEntitlements() async -> [PurchaseRecord] {
        var records: [PurchaseRecord] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil else { continue }
            records.append(transaction.toPurchaseRecord())
        }
        return records
    }

    private func performPurchase(skProduct: Product) async {
        do {
            let result = try await skProduct.purchase()
            switch result {
            case let .success(.verified(transaction)):
                let record = transaction.toPurchaseRecord()
                let productDetail = cachedProducts[record.productId]?.toBillingProductDetail()

                // Mark as handled so the update stream doesn't double-process it.
                handledTransactionIDs.insert(transaction.id)

                adjustTracker?.trackPurchase(purchase: record, billingProductDetail: productDetail)
                await transaction.finish()

                emitUpdate(.succeeded([PurchasedItem(record: record, productDetail: productDetail)]))

            case .success(.unverified):
                emitUpdate(.error)

            case .pending:
                emitUpdate(.pending)

            case .userCancelled:
                emitUpdate(.userCanceled)

            @unknown default:
                emitUpdate(.error)
            }
        } catch {
            emitUpdate(.error)
        }
    }
}

// MARK: - StoreKit → domain model mappers

private extension Transaction {
    func toPurchaseRecord() -> PurchaseRecord {
        return PurchaseRecord(
            productId: productID,
            purchaseToken: originalID.description,  // stable across renewals
            purchaseTime: Int64(purchaseDate.timeIntervalSince1970 * 1000),
            orderId: id.description,
            isPurchased: revocationDate == nil,
            isAcknowledged: true  // StoreKit 2: always true after transaction.finish()
        )
    }
}

private extension Product {
    func toBillingProductDetail() -> BillingProductDetail {
        switch type {
        case .autoRenewable:
            return makeSubscriptionDetail()
        case .consumable, .nonConsumable:
            return makeInAppDetail()
        default:
            return makeInAppDetail()
        }
    }

    private func makeInAppDetail() -> BillingProductDetail {
        BillingProductDetail(
            productId: id,
            name: displayName,
            productType: "inapp",
            description: description,
            oneTimePurchaseOfferDetails: OneTimePurchaseOfferDetails(
                formattedPrice: displayPrice,
                priceAmountMicros: priceInMicros,
                priceCurrencyCode: priceFormatStyle.currencyCode
            ),
            subscriptionPeriod: nil,
            basePlanFormattedPrice: nil,
            basePlanPriceAmountMicros: 0,
            basePlanCurrencyCode: nil,
            introductoryOffer: nil,
            promotionalOffers: []
        )
    }

    private func makeSubscriptionDetail() -> BillingProductDetail {
        let sub = subscription
        let periodStr = sub.map { billingPeriodString(from: $0.subscriptionPeriod) }

        // Introductory offer — at most one, always offerId = nil on iOS.
        let introOffer: SubscriptionOfferDetail? = sub.flatMap { info in
            info.introductoryOffer.map { makeOffer(from: $0, offerId: nil) }
        }

        // Promotional offers (offer codes) — each has a non-nil id.
        let promoOffers: [SubscriptionOfferDetail] = sub?.promotionalOffers
            .map { makeOffer(from: $0, offerId: $0.id) } ?? []

        return BillingProductDetail(
            productId: id,
            name: displayName,
            productType: "subs",
            description: description,
            oneTimePurchaseOfferDetails: nil,
            subscriptionPeriod: periodStr,
            basePlanFormattedPrice: displayPrice,
            basePlanPriceAmountMicros: priceInMicros,
            basePlanCurrencyCode: priceFormatStyle.currencyCode,
            introductoryOffer: introOffer,
            promotionalOffers: promoOffers
        )
    }

    private var priceInMicros: Int64 {
        Int64((price as NSDecimalNumber).doubleValue * 1_000_000)
    }

    private func makeOffer(
        from offer: Product.SubscriptionOffer,
        offerId: String?
    ) -> SubscriptionOfferDetail {
        let paymentMode: SubscriptionOfferDetail.PaymentMode
        switch offer.paymentMode {
        case .freeTrial:  paymentMode = .freeTrial
        case .payUpFront: paymentMode = .payUpFront
        case .payAsYouGo: paymentMode = .payAsYouGo
        default:          paymentMode = .payAsYouGo
        }

        return SubscriptionOfferDetail(
            offerId: offerId,
            paymentMode: paymentMode,
            priceAmountMicros: Int64((offer.price as NSDecimalNumber).doubleValue * 1_000_000),
            formattedPrice: offer.paymentMode == .freeTrial ? "Free" : offer.displayPrice,
            priceCurrencyCode: priceFormatStyle.currencyCode,
            billingPeriod: billingPeriodString(from: offer.period),
            billingCycleCount: offer.periodCount
        )
    }

    private func billingPeriodString(from period: Product.SubscriptionPeriod) -> String {
        switch period.unit {
        case .day:   return "P\(period.value)D"
        case .week:  return "P\(period.value * 7)D"
        case .month: return "P\(period.value)M"
        case .year:  return "P\(period.value)Y"
        @unknown default: return "P1M"
        }
    }
}
