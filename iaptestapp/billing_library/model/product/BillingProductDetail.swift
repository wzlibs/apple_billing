import Foundation

struct BillingProductDetail {
    let productId: String
    let name: String
    /// `"subs"` for auto-renewable subscriptions, `"inapp"` for one-time purchases.
    let productType: String
    let description: String

    // MARK: - One-time purchases
    let oneTimePurchaseOfferDetails: OneTimePurchaseOfferDetails?

    // MARK: - Subscription base plan
    /// ISO 8601 billing period of the base plan (e.g. `"P1M"`). `nil` for non-subscriptions.
    let subscriptionPeriod: String?
    let basePlanFormattedPrice: String?
    let basePlanPriceAmountMicros: Int64
    let basePlanCurrencyCode: String?

    // MARK: - Subscription offers
    /// Introductory offer (free trial or reduced price). At most one is active at a time on iOS.
    let introductoryOffer: SubscriptionOfferDetail?
    /// Promotional offers (offer codes / promo codes).
    let promotionalOffers: [SubscriptionOfferDetail]
}

extension BillingProductDetail {
    func isSubscription() -> Bool { productType == "subs" }

    /// Formatted price to show on a paywall — intro price if available, otherwise base price.
    func getFormattedPrice() -> String {
        if isSubscription() {
            return introductoryOffer?.formattedPrice ?? basePlanFormattedPrice ?? ""
        }
        return oneTimePurchaseOfferDetails?.formattedPrice ?? ""
    }

    /// Base-plan price in micros — what the user pays after any intro period ends.
    func getRecurringPriceAmountMicros() -> Int64 {
        if isSubscription() { return basePlanPriceAmountMicros }
        return oneTimePurchaseOfferDetails?.priceAmountMicros ?? 0
    }

    func getRecurringPriceCurrencyCode() -> String {
        if isSubscription() { return basePlanCurrencyCode ?? "" }
        return oneTimePurchaseOfferDetails?.priceCurrencyCode ?? ""
    }

    func getRecurringPricePerDay(days: Int) -> String {
        guard days > 0 else { return "" }
        let micros = getRecurringPriceAmountMicros()
        let currency = getRecurringPriceCurrencyCode()
        guard micros > 0 else { return String(format: "%.2f %@", 0.0, currency) }
        let perDay = Double(micros) / 1_000_000.0 / Double(days)
        return String(format: "%.2f %@", perDay, currency)
    }

    func toJSONString() -> String {
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
