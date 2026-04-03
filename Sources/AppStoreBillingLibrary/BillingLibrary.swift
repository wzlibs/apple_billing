@MainActor
public protocol BillingLibrary: AnyObject {

    func setPurchaseUpdateListener(_ listener: ((PurchaseUpdate) -> Void)?)

    func connect() async -> BillingConnectionResult

    func queryProductDetailsAndPurchases(
        products: [BillingProduct]
    ) async -> BillingQueryResult

    func purchase(productId: String)

    /// Refreshes the App Store receipt so purchases from other devices become visible.
    /// Call from a "Restore Purchases" button.
    func restorePurchases() async

    /// Opens the App Store subscription management sheet so the user can cancel.
    /// iOS does not allow apps to cancel subscriptions programmatically.
    func showManageSubscriptions() async

    func endConnection()
}
