import StoreKit
import Foundation

@MainActor
public class AppStoreBillingLibrary: BillingLibrary {

    private var purchaseUpdateListener: ((PurchaseUpdate) -> Void)?
    private var transactionObserverTask: Task<Void, Never>?

    private var billingProducts: [String: BillingProduct] = [:]
    private var cachedProducts: [String: Product] = [:]
    private var pendingUserInitiatedProductIDs: Set<String> = []

    /// Các transaction ID đã được xử lý trong phiên hiện tại, trên mọi luồng xử lý
    /// (performPurchase, Transaction.updates, Transaction.unfinished).
    /// Luồng nào thắng race trước sẽ được xử lý, các luồng còn lại sẽ bỏ qua.
    private var processedTransactionIDs: Set<UInt64> = []

    private let adjustTracker: AdjustIapTracker?

    public init(adjustTracker: AdjustIapTracker? = nil) {
        self.adjustTracker = adjustTracker
    }

    deinit {
        transactionObserverTask?.cancel()
    }

    // MARK: - BillingLibrary

    public func setPurchaseUpdateListener(_ listener: ((PurchaseUpdate) -> Void)?) {
        self.purchaseUpdateListener = listener
    }

    public func connect() async -> BillingConnectionResult {
        transactionObserverTask = observeTransactionUpdates()
        return .connected
    }

    public func queryProductDetailsAndPurchases(
        products: [BillingProduct]
    ) async -> BillingQueryResult {
        products.forEach { billingProducts[$0.productId] = $0 }

        async let productsTask = fetchProducts(ids: products.map { $0.productId })
        async let entitlementsTask = fetchCurrentEntitlements()

        let (skProducts, purchaseRecords) = await (productsTask, entitlementsTask)

        cachedProducts = skProducts
        let billingProductDetails = skProducts.values.map { $0.toBillingProductDetail() }

        // Xử lý unfinished transactions sau khi cachedProducts đã có data,
        // để Adjust có thể track đúng productDetail.
        await processUnfinishedTransactions()

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

    public func purchase(productId: String) {
        guard let skProduct = cachedProducts[productId] else {
            emitUpdate(.error)
            return
        }
        pendingUserInitiatedProductIDs.insert(productId)
        print("""
        [BillingLibrary] ──── purchase() PRODUCT INFO ────
          productId   : \(skProduct.id)
          displayName : \(skProduct.displayName)
          description : \(skProduct.description)
          type        : \(skProduct.type)
          price       : \(skProduct.price)
          displayPrice: \(skProduct.displayPrice)
          isFamilyShareable: \(skProduct.isFamilyShareable)
        ─────────────────────────────────────────────────────────
        """)
        Task { await performPurchase(skProduct: skProduct) }
    }

    /// Yêu cầu App Store làm mới receipt để các giao dịch được mua trên thiết bị
    /// khác hoặc khôi phục từ backup có thể hiển thị. Gọi hàm này từ nút
    /// "Restore Purchases".
    public func restorePurchases() async -> [PurchasedItem] {
        do {
            try await AppStore.sync()
        } catch {
            print("[BillingLibrary] AppStore.sync() failed: \(error)")
        }
        let records = await fetchCurrentEntitlements()
        return records.map { record in
            PurchasedItem(
                record: record,
                productDetail: cachedProducts[record.productId]?.toBillingProductDetail()
            )
        }
    }

    /// Mở màn hình quản lý thuê bao của App Store để người dùng có thể hủy.
    /// Nếu không có window scene khả dụng thì fallback sang mở URL của App Store.
    public func showManageSubscriptions() async {
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

    /// StoreKit 2 không có thao tác disconnect tường minh, nên chỉ cần hủy observer task.
    public func endConnection() {
        transactionObserverTask?.cancel()
        transactionObserverTask = nil
    }

    // MARK: - Private

    private func emitUpdate(_ update: PurchaseUpdate) {
        purchaseUpdateListener?(update)
    }

    /// Trả về `true` nếu người dùng đang có entitlement hợp lệ và chưa bị thu hồi cho `productID`.
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

    /// Lắng nghe `Transaction.updates` cho các lần gia hạn, giao dịch phát sinh nền,
    /// và các giao dịch Ask-to-Buy được duyệt. Apple khuyến nghị khởi động listener này ngay khi app mở.
    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                await self.handleTransactionUpdate(result)
            }
        }
    }

    private func processUnfinishedTransactions() async {
        for await result in Transaction.unfinished {
            guard case .verified(let transaction) = result else { continue }

            // Đánh dấu đã xử lý để Transaction.updates không gửi lại và xử lý trùng.
            guard processedTransactionIDs.insert(transaction.id).inserted else { continue }
            logTransaction(transaction, tag: "UNFINISHED")

            // Track với Adjust phòng trường hợp app đã crash trước khi hoàn tất ở phiên trước.
            if transaction.revocationDate == nil {
                let record = transaction.toPurchaseRecord()
                let productDetail = cachedProducts[record.productId]?.toBillingProductDetail()
                adjustTracker?.trackPurchase(purchase: record, billingProductDetail: productDetail)
            }

            await transaction.finish()
        }
    }

    private func consumeUserInitiatedPurchaseIntent(for productId: String) -> Bool {
        pendingUserInitiatedProductIDs.remove(productId) != nil
    }

    private func handleTransactionUpdate(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .unverified:
            print("[BillingLibrary] Transaction.updates received UNVERIFIED transaction")
            // Receipt bị can thiệp, không cấp quyền truy cập.
            emitUpdate(.error)

        case .verified(let transaction):
            print(
                "[BillingLibrary] Transaction.updates received VERIFIED transaction id=\(transaction.id) productId=\(transaction.productID)"
            )
            // Luồng nào nhận transaction trước sẽ xử lý, các luồng còn lại bỏ qua.
            guard processedTransactionIDs.insert(transaction.id).inserted else {
                print(
                    "[BillingLibrary] Transaction.updates skipped duplicate transaction id=\(transaction.id)"
                )
                await transaction.finish()
                return
            }

            logTransaction(transaction, tag: "RENEWAL/UPDATE")

            if transaction.revocationDate != nil {
                // Subscription đã bị thu hồi (refund / chargeback).
                // Finish transaction và báo cho caller kiểm tra lại entitlements.
                await transaction.finish()
                emitUpdate(.error)
                return
            }

            let record = transaction.toPurchaseRecord()
            let productDetail = cachedProducts[record.productId]?.toBillingProductDetail()

            adjustTracker?.trackPurchase(purchase: record, billingProductDetail: productDetail)

            if consumeUserInitiatedPurchaseIntent(for: transaction.productID) {
                print(
                    "[BillingLibrary] Transaction.updates emitting succeeded for user-initiated purchase productId=\(transaction.productID)"
                )
                emitUpdate(.succeeded([PurchasedItem(record: record, productDetail: productDetail)]))
            } else {
                print(
                    "[BillingLibrary] Transaction.updates processed background transaction without emitting UI success for productId=\(transaction.productID)"
                )
            }
            await transaction.finish()
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
        print("[BillingLibrary] performPurchase started for productId=\(skProduct.id)")

        if await isEntitled(for: skProduct.id) {
            _ = consumeUserInitiatedPurchaseIntent(for: skProduct.id)
            print("[BillingLibrary] performPurchase blocked because user is already entitled to productId=\(skProduct.id)")
            emitUpdate(.alreadyOwned)
            return
        }

        do {
            let result = try await skProduct.purchase()
            switch result {
            case let .success(.verified(transaction)):
                print(
                    "[BillingLibrary] performPurchase received VERIFIED transaction id=\(transaction.id) productId=\(transaction.productID)"
                )
                let record = transaction.toPurchaseRecord()
                let productDetail = cachedProducts[record.productId]?.toBillingProductDetail()

                guard processedTransactionIDs.insert(transaction.id).inserted else {
                    print(
                        "[BillingLibrary] performPurchase skipped duplicate transaction id=\(transaction.id)"
                    )
                    await transaction.finish()
                    return
                }

                logTransaction(transaction, tag: "FIRST PURCHASE")

                adjustTracker?.trackPurchase(purchase: record, billingProductDetail: productDetail)
                await transaction.finish()
                _ = consumeUserInitiatedPurchaseIntent(for: skProduct.id)
                print(
                    "[BillingLibrary] performPurchase emitting succeeded for user-initiated purchase productId=\(skProduct.id)"
                )
                emitUpdate(.succeeded([PurchasedItem(record: record, productDetail: productDetail)]))

            case .success(.unverified):
                _ = consumeUserInitiatedPurchaseIntent(for: skProduct.id)
                print("[BillingLibrary] performPurchase received UNVERIFIED transaction for productId=\(skProduct.id)")
                emitUpdate(.error)

            case .pending:
                print("[BillingLibrary] performPurchase result is PENDING for productId=\(skProduct.id)")
                emitUpdate(.pending)

            case .userCancelled:
                _ = consumeUserInitiatedPurchaseIntent(for: skProduct.id)
                print("[BillingLibrary] performPurchase result is USER_CANCELLED for productId=\(skProduct.id)")
                emitUpdate(.userCanceled)

            @unknown default:
                _ = consumeUserInitiatedPurchaseIntent(for: skProduct.id)
                print("[BillingLibrary] performPurchase result is UNKNOWN for productId=\(skProduct.id)")
                emitUpdate(.error)
            }
        } catch {
            _ = consumeUserInitiatedPurchaseIntent(for: skProduct.id)
            print("[BillingLibrary] performPurchase threw error for productId=\(skProduct.id): \(error)")
            emitUpdate(.error)
        }
    }

    // MARK: - Ghi log debug

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
        ────────────────────────────────────────────
        """)
    }
}

// MARK: - Mapper từ StoreKit sang domain model

private extension Transaction {
    func toPurchaseRecord() -> PurchaseRecord {
        return PurchaseRecord(
            productId: productID,
            purchaseToken: originalID.description,  // giữ nguyên qua các lần gia hạn
            purchaseTime: Int64(purchaseDate.timeIntervalSince1970 * 1000),
            orderId: id.description,
            isPurchased: revocationDate == nil,
            expirationTime: expirationDate.map { Int64($0.timeIntervalSince1970 * 1000) },
            originalPurchaseTime: Int64(originalPurchaseDate.timeIntervalSince1970 * 1000)
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

        // Offer giới thiệu: tối đa một cái, và offerId luôn là nil trên iOS.
        let introOffer: SubscriptionOfferDetail? = sub.flatMap { info in
            info.introductoryOffer.map { makeOffer(from: $0, offerId: nil) }
        }

        // Offer khuyến mãi (offer code): mỗi offer sẽ có id khác nil.
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
