public struct BillingProduct {
    public let productId: String
    public let type: BillingProductType

    public init(productId: String, type: BillingProductType) {
        self.productId = productId
        self.type = type
    }
}
