public struct PurchaseRecord {
    public let productId: String
    public let purchaseToken: String      // on iOS: originalTransactionID
    public let purchaseTime: Int64        // milliseconds since epoch
    public let orderId: String?           // on iOS: transactionID
    public let isPurchased: Bool
    public let expirationTime: Int64?     // milliseconds since epoch; nil for one-time purchases

    public init(productId: String, purchaseToken: String, purchaseTime: Int64,
                orderId: String?, isPurchased: Bool, expirationTime: Int64?) {
        self.productId = productId
        self.purchaseToken = purchaseToken
        self.purchaseTime = purchaseTime
        self.orderId = orderId
        self.isPurchased = isPurchased
        self.expirationTime = expirationTime
    }
}
