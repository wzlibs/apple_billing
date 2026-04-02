struct PurchaseRecord {
    let productId: String
    let purchaseToken: String      // on iOS: originalTransactionID
    let purchaseTime: Int64        // milliseconds since epoch
    let orderId: String?           // on iOS: transactionID
    let isPurchased: Bool
    let expirationTime: Int64?     // milliseconds since epoch; nil for one-time purchases
}
