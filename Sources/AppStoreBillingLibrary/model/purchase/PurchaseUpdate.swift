public enum PurchaseUpdate {
    case succeeded([PurchasedItem])
    case alreadyOwned
    case userCanceled
    case pending
    case error
}
