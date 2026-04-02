struct SubscriptionOfferDetail {
    enum PaymentMode {
        /// Price is zero — user gets the offer period for free.
        case freeTrial
        /// Discounted amount is charged up-front for all offer cycles at once.
        case payUpFront
        /// Discounted amount is charged each billing cycle until the offer ends.
        case payAsYouGo
    }

    /// `nil` identifies the introductory offer; a non-nil string is a promotional offer id.
    let offerId: String?

    let paymentMode: PaymentMode

    /// Price in micros (1/1,000,000 of the currency unit). `0` for a free trial.
    let priceAmountMicros: Int64
    let formattedPrice: String
    let priceCurrencyCode: String

    /// ISO 8601 billing period string, e.g. `"P1M"`, `"P1W"`.
    let billingPeriod: String

    /// Number of billing periods this offer covers.
    let billingCycleCount: Int
}

extension SubscriptionOfferDetail {
    var isTrial: Bool { paymentMode == .freeTrial }
    var isIntroductory: Bool { offerId == nil }
}
