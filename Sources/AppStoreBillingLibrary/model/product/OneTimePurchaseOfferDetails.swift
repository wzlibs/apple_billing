public struct OneTimePurchaseOfferDetails {
    public let formattedPrice: String
    public let priceAmountMicros: Int64
    public let priceCurrencyCode: String

    public init(formattedPrice: String, priceAmountMicros: Int64, priceCurrencyCode: String) {
        self.formattedPrice = formattedPrice
        self.priceAmountMicros = priceAmountMicros
        self.priceCurrencyCode = priceCurrencyCode
    }
}
