public struct SubscriptionOfferDetail {
    public enum PaymentMode {
        /// Price is zero — user gets the offer period for free.
        case freeTrial
        /// Discounted amount is charged up-front for all offer cycles at once.
        case payUpFront
        /// Discounted amount is charged each billing cycle until the offer ends.
        case payAsYouGo
    }

    /// `nil` identifies the introductory offer; a non-nil string is a promotional offer id.
    public let offerId: String?

    public let paymentMode: PaymentMode

    /// Price in micros (1/1,000,000 of the currency unit). `0` for a free trial.
    public let priceAmountMicros: Int64
    public let formattedPrice: String
    public let priceCurrencyCode: String

    /// ISO 8601 billing period string, e.g. `"P1M"`, `"P1W"`.
    public let billingPeriod: String

    /// Number of billing periods this offer covers.
    public let billingCycleCount: Int

    public init(offerId: String?, paymentMode: PaymentMode, priceAmountMicros: Int64,
                formattedPrice: String, priceCurrencyCode: String,
                billingPeriod: String, billingCycleCount: Int) {
        self.offerId = offerId
        self.paymentMode = paymentMode
        self.priceAmountMicros = priceAmountMicros
        self.formattedPrice = formattedPrice
        self.priceCurrencyCode = priceCurrencyCode
        self.billingPeriod = billingPeriod
        self.billingCycleCount = billingCycleCount
    }
}

extension SubscriptionOfferDetail {
    public var isTrial: Bool { paymentMode == .freeTrial }
    public var isIntroductory: Bool { offerId == nil }
}
