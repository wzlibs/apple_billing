import Foundation

public struct BillingProductDetail {
    public let productId: String
    public let name: String
    /// `"subs"` for auto-renewable subscriptions, `"inapp"` for one-time purchases.
    public let productType: String
    public let description: String

    // MARK: - One-time purchases
    public let oneTimePurchaseOfferDetails: OneTimePurchaseOfferDetails?

    // MARK: - Subscription base plan
    /// ISO 8601 billing period of the base plan (e.g. `"P1M"`). `nil` for non-subscriptions.
    public let subscriptionPeriod: String?
    public let basePlanFormattedPrice: String?
    public let basePlanPriceAmountMicros: Int64
    public let basePlanCurrencyCode: String?

    // MARK: - Subscription offers
    /// Introductory offer (free trial or reduced price). At most one is active at a time on iOS.
    public let introductoryOffer: SubscriptionOfferDetail?
    /// Promotional offers (offer codes / promo codes).
    public let promotionalOffers: [SubscriptionOfferDetail]

    public init(productId: String, name: String, productType: String, description: String,
                oneTimePurchaseOfferDetails: OneTimePurchaseOfferDetails?,
                subscriptionPeriod: String?, basePlanFormattedPrice: String?,
                basePlanPriceAmountMicros: Int64, basePlanCurrencyCode: String?,
                introductoryOffer: SubscriptionOfferDetail?,
                promotionalOffers: [SubscriptionOfferDetail]) {
        self.productId = productId
        self.name = name
        self.productType = productType
        self.description = description
        self.oneTimePurchaseOfferDetails = oneTimePurchaseOfferDetails
        self.subscriptionPeriod = subscriptionPeriod
        self.basePlanFormattedPrice = basePlanFormattedPrice
        self.basePlanPriceAmountMicros = basePlanPriceAmountMicros
        self.basePlanCurrencyCode = basePlanCurrencyCode
        self.introductoryOffer = introductoryOffer
        self.promotionalOffers = promotionalOffers
    }
}

extension BillingProductDetail {
    public func isSubscription() -> Bool { productType == "subs" }

    /// Formatted price to show on a paywall — intro price if available, otherwise base price.
    public func getFormattedPrice() -> String {
        if isSubscription() {
            return introductoryOffer?.formattedPrice ?? basePlanFormattedPrice ?? ""
        }
        return oneTimePurchaseOfferDetails?.formattedPrice ?? ""
    }

    /// Base-plan price in micros — what the user pays after any intro period ends.
    public func getRecurringPriceAmountMicros() -> Int64 {
        if isSubscription() { return basePlanPriceAmountMicros }
        return oneTimePurchaseOfferDetails?.priceAmountMicros ?? 0
    }

    public func getRecurringPriceCurrencyCode() -> String {
        if isSubscription() { return basePlanCurrencyCode ?? "" }
        return oneTimePurchaseOfferDetails?.priceCurrencyCode ?? ""
    }

    public func getRecurringPricePerDay(days: Int) -> String {
        guard days > 0 else { return "" }
        let micros = getRecurringPriceAmountMicros()
        let currency = getRecurringPriceCurrencyCode()
        guard micros > 0 else { return String(format: "%.2f %@", 0.0, currency) }
        let perDay = Double(micros) / 1_000_000.0 / Double(days)
        return String(format: "%.2f %@", perDay, currency)
    }

    public func toJSONString() -> String {
        func offerDict(_ o: SubscriptionOfferDetail) -> [String: Any] {
            [
                "offerId":          o.offerId as Any,
                "paymentMode":      "\(o.paymentMode)",
                "priceAmountMicros": o.priceAmountMicros,
                "formattedPrice":   o.formattedPrice,
                "priceCurrencyCode": o.priceCurrencyCode,
                "billingPeriod":    o.billingPeriod,
                "billingCycleCount": o.billingCycleCount,
                "isTrial":          o.isTrial
            ]
        }

        var dict: [String: Any] = [
            "productId":   productId,
            "name":        name,
            "productType": productType,
            "description": description
        ]

        if let one = oneTimePurchaseOfferDetails {
            dict["oneTimePurchaseOfferDetails"] = [
                "formattedPrice":    one.formattedPrice,
                "priceAmountMicros": one.priceAmountMicros,
                "priceCurrencyCode": one.priceCurrencyCode
            ]
        }

        dict["subscriptionPeriod"]       = subscriptionPeriod as Any
        dict["basePlanFormattedPrice"]   = basePlanFormattedPrice as Any
        dict["basePlanPriceAmountMicros"] = basePlanPriceAmountMicros
        dict["basePlanCurrencyCode"]     = basePlanCurrencyCode as Any

        if let intro = introductoryOffer {
            dict["introductoryOffer"] = offerDict(intro)
        }
        dict["promotionalOffers"] = promotionalOffers.map { offerDict($0) }

        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}
