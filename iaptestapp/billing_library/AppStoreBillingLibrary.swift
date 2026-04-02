import StoreKit
import Foundation

@MainActor
class AppStoreBillingLibrary: BillingLibrary {

    private var purchaseUpdateListener: ((PurchaseUpdate) -> Void)?
    private var transactionObserverTask: Task<Void, Never>?

    private var billingProducts: [String: BillingProduct] = [:]
    private var cachedProducts: [String: Product] = [:]

    /// Transaction IDs already processed this session, across all delivery paths
    /// (performPurchase, Transaction.updates, Transaction.unfinished).
    /// Whichever path wins the race gets to process; all others skip.
    private var processedTransactionIDs: Set<UInt64> = []

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

    /// Starts the live transaction observer and finishes any transactions that were left
    /// unfinished in previous sessions (crash, Ask-to-Buy, SCA, etc.).
    func connect() async -> BillingConnectionResult {
        transactionObserverTask = observeTransactionUpdates()
        await processUnfinishedTransactions()
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

    /// Requests an App Store receipt refresh so purchases made on other devices or
    /// restored from backup become visible. Call this from a "Restore Purchases" button.
    func restorePurchases() async {
        do {
            try await AppStore.sync()
        } catch {
            print("[BillingLibrary] AppStore.sync() failed: \(error)")
        }
    }

    /// Opens the App Store subscription management sheet so the user can cancel.
    /// Falls back to opening the App Store URL if no window scene is available.
    func showManageSubscriptions() async {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
            let url = URL(string: "https://apps.apple.com/account/subscriptions")!
            await UIApplication.shared.open(url)
            return
        }
        do {
            try await AppStore.showManageSubscriptions(in: scene)
        } catch {
            print("[BillingLibrary] showManageSubscriptions failed: \(error)")
        }
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

    /// Returns `true` if the user has a current, non-revoked entitlement for `productID`.
    private func isEntitled(for productID: String) async -> Bool {
        for await result in Transaction.currentEntitlements {
            if case .verified(let tx) = result,
               tx.productID == productID,
               tx.revocationDate == nil {
                return true
            }
        }
        return false
    }

    /// Listens to `Transaction.updates` for renewals, background purchases, and
    /// Ask-to-Buy approvals. Apple recommends starting this listener at app launch.
    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                await self.handleTransactionUpdate(result)
            }
        }
    }

    /// Finishes any transactions left pending from a previous app session (crash, kill, etc.).
    /// Tracks revenue with Adjust in case it was missed before the crash, then calls finish().
    /// Does NOT emit UI updates — entitlement state is already read via currentEntitlements.
    private func processUnfinishedTransactions() async {
        for await result in Transaction.unfinished {
            guard case .verified(let transaction) = result else { continue }

            // Mark processed so Transaction.updates won't re-deliver and double-process.
            guard processedTransactionIDs.insert(transaction.id).inserted else { continue }

            logTransaction(transaction, tag: "UNFINISHED")

            // Track with Adjust in case the app crashed before this completed last session.
            if transaction.revocationDate == nil {
                let record = transaction.toPurchaseRecord()
                let productDetail = cachedProducts[record.productId]?.toBillingProductDetail()
                adjustTracker?.trackPurchase(purchase: record, billingProductDetail: productDetail)
            }

            await transaction.finish()
        }
    }

    /// Core transaction handler — used by both the live update stream and the
    /// unfinished-transaction sweep. Always calls `finish()` on verified transactions.
    private func handleTransactionUpdate(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .unverified:
            // Tampered receipt — do not grant access.
            emitUpdate(.error)

        case .verified(let transaction):
            // Whichever delivery path arrives first wins; all others skip.
            guard processedTransactionIDs.insert(transaction.id).inserted else {
                await transaction.finish()
                return
            }

            logTransaction(transaction, tag: "RENEWAL/UPDATE")

            if transaction.revocationDate != nil {
                // Subscription was revoked (refund / chargeback).
                // Finish the transaction and signal the caller to re-check entitlements.
                await transaction.finish()
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
            logTransaction(transaction, tag: "ENTITLEMENT")
            records.append(transaction.toPurchaseRecord())
        }
        return records
    }

    private func performPurchase(skProduct: Product) async {
        // Guard against re-purchasing an already-active subscription.
        if await isEntitled(for: skProduct.id) {
            emitUpdate(.alreadyOwned)
            return
        }

        do {
            let result = try await skProduct.purchase()
            switch result {
            case let .success(.verified(transaction)):
                let record = transaction.toPurchaseRecord()
                let productDetail = cachedProducts[record.productId]?.toBillingProductDetail()

                // If Transaction.updates already processed this transaction (race condition),
                // just finish and return — .succeeded was already emitted.
                guard processedTransactionIDs.insert(transaction.id).inserted else {
                    await transaction.finish()
                    return
                }

                logTransaction(transaction, tag: "FIRST PURCHASE")

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

    // MARK: - Debug logging

    private func logTransaction(_ tx: Transaction, tag: String) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = .current

        let purchaseDate      = df.string(from: tx.purchaseDate)
        let expirationDate    = tx.expirationDate.map { df.string(from: $0) } ?? "nil"
        let revocationDate    = tx.revocationDate.map { df.string(from: $0) } ?? "nil"
        let originalPurchDate = df.string(from: tx.originalPurchaseDate)

        print("""
        [BillingLibrary] ──── Transaction \(tag) ────
          productId        : \(tx.productID)
          transactionId    : \(tx.id)            ← orderId in PurchaseRecord, changes every renewal
          originalId       : \(tx.originalID)    ← purchaseToken in PurchaseRecord, stable across renewals
          purchaseDate     : \(purchaseDate)      ← purchaseTime in PurchaseRecord, date of THIS renewal
          originalPurchDate: \(originalPurchDate) ← date of first purchase
          expirationDate   : \(expirationDate)
          revocationDate   : \(revocationDate)
          productType      : \(tx.productType)
          environment      : \(tx.environment)
        ────────────────────────────────────────────
        """)
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
            expirationTime: expirationDate.map { Int64($0.timeIntervalSince1970 * 1000) }
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
