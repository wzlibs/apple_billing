public struct PurchasedItem {
    public let record: PurchaseRecord
    public let productDetail: BillingProductDetail?

    public init(record: PurchaseRecord, productDetail: BillingProductDetail?) {
        self.record = record
        self.productDetail = productDetail
    }
}
