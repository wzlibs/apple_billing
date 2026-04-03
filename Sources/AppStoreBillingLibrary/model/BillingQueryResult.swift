public struct BillingQueryResult {
    public let productDetails: [BillingProductDetail]
    public let purchaseRecords: [PurchaseRecord]

    public init(productDetails: [BillingProductDetail], purchaseRecords: [PurchaseRecord]) {
        self.productDetails = productDetails
        self.purchaseRecords = purchaseRecords
    }
}
