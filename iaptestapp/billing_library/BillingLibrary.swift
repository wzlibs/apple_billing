@MainActor
protocol BillingLibrary: AnyObject {

    func setPurchaseUpdateListener(_ listener: ((PurchaseUpdate) -> Void)?)

    func connect() async -> BillingConnectionResult

    func queryProductDetailsAndPurchases(
        products: [BillingProduct]
    ) async -> BillingQueryResult

    func purchase(product: BillingProductDetail)

    func endConnection()
}
