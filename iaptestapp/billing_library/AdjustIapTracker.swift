import Foundation

/// Tracks IAP revenue to Adjust for ad-spend decision-making.
///
/// Two tracking paths:
///
/// 1. `trackPurchase` — called immediately after a successful purchase.
///    Logs the first charge only. Skips free trials (price = 0).
///    Deduped by `cycleKey(token, purchaseTime)`.
///
/// 2. `trackPurchases` — called on each app open.
///    Logs only the subscription cycle the user is currently in.
///    If the user missed opening the app during a previous cycle, that cycle is
///    skipped — only the latest active cycle is logged.
///    Deduped per cycle by `cycleKey(token, chargeTime)`.
class AdjustIapTracker {

    private let eventToken: String
    private let prefs: UserDefaults

    private static let prefsName = "adjust_iap_tracker"

    /// Represents a single billable cycle that is pending to be sent to Adjust.
    private typealias PendingCycle = (chargeTimeMs: Int64, price: Double, currency: String, dedupId: String)

    init(eventToken: String) {
        self.eventToken = eventToken
        self.prefs = UserDefaults(suiteName: AdjustIapTracker.prefsName) ?? .standard
    }

    // MARK: - First purchase

    /// Called right after a successful purchase. Logs the initial charge if price > 0.
    func trackPurchase(
        purchase: PurchaseRecord,
        billingProductDetail: BillingProductDetail?
    ) {
        guard let detail = billingProductDetail else { return }
        let token = purchase.purchaseToken
        let key = cycleKey(token: token, chargeTimeMs: purchase.purchaseTime)

        guard !prefs.bool(forKey: key) else {
            print("[AdjustIapTracker] trackPurchase SKIP (already logged): token=\(token)")
            return
        }

        let (price, currency) = firstChargePrice(detail: detail)

        guard price > 0.0 else {
            print("[AdjustIapTracker] trackPurchase SKIP (trial/free): productId=\(purchase.productId)")
            return
        }

        sendToAdjust(price: price, currency: currency, purchase: purchase,
                     productType: detail.productType, adjustDedupId: token)
        prefs.set(true, forKey: key)
    }

    // MARK: - Subscription renewals

    /// Called on each app open. Logs the current renewal cycle for each active subscription.
    func trackPurchases(
        purchases: [PurchaseRecord],
        productDetails: [String: BillingProductDetail]
    ) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for purchase in purchases where purchase.isPurchased {
            guard let detail = productDetails[purchase.productId],
                  detail.isSubscription() else { continue }
            trackSubscriptionRenewals(purchase: purchase, detail: detail, now: now)
        }
    }

    /// Coordinates finding and logging the current renewal cycle for one subscription.
    private func trackSubscriptionRenewals(
        purchase: PurchaseRecord,
        detail: BillingProductDetail,
        now: Int64
    ) {
        guard let basePeriod = detail.subscriptionPeriod,
              detail.basePlanPriceAmountMicros > 0,
              let baseCurrency = detail.basePlanCurrencyCode,
              let baseParsed = parsePeriod(basePeriod) else { return }

        let token = purchase.purchaseToken
        var chargeTimeMs = purchase.purchaseTime

        // Walk through the intro/trial phase; chargeTimeMs is advanced to the
        // start of the base-plan period upon return.
        let latestIntroCycle = processIntroCycles(
            intro: detail.introductoryOffer,
            token: token,
            purchase: purchase,
            chargeTimeMs: &chargeTimeMs,
            now: now
        )

        // Find the latest unlogged base-plan cycle (the one currently active).
        // If the user is still inside the intro/trial window, chargeTimeMs > now
        // and this returns nil.
        let latestBaseCycle = findLatestPendingBaseCycle(
            startingAt: chargeTimeMs,
            period: baseParsed,
            price: Double(detail.basePlanPriceAmountMicros) / 1_000_000.0,
            currency: baseCurrency,
            token: token,
            purchase: purchase,
            now: now
        )

        // Base cycle takes priority. Fall back to intro cycle only if the user
        // is still inside the intro phase.
        guard let cycle = latestBaseCycle ?? latestIntroCycle else { return }

        sendToAdjust(
            price: cycle.price,
            currency: cycle.currency,
            purchase: purchase,
            productType: detail.productType,
            adjustDedupId: cycle.dedupId
        )
        prefs.set(true, forKey: cycle.dedupId)
    }

    /// Advances `chargeTimeMs` past the trial/intro window.
    /// Returns the latest unlogged paid-intro cycle, or `nil` for a free trial or no intro.
    private func processIntroCycles(
        intro: SubscriptionOfferDetail?,
        token: String,
        purchase: PurchaseRecord,
        chargeTimeMs: inout Int64,
        now: Int64
    ) -> PendingCycle? {
        guard let intro, let period = parsePeriod(intro.billingPeriod) else { return nil }

        if intro.isTrial {
            // Free trial: advance past trial with no charge to log.
            chargeTimeMs = addPeriod(epochMs: chargeTimeMs, period: period)
            return nil
        }

        // Paid intro: walk each discounted cycle, remember the latest unlogged one.
        var latest: PendingCycle?
        for _ in 0..<intro.billingCycleCount {
            if chargeTimeMs > now { break }
            let next = addPeriod(epochMs: chargeTimeMs, period: period)
            // Skip purchaseTime — already logged by trackPurchase.
            if chargeTimeMs > purchase.purchaseTime, intro.priceAmountMicros > 0 {
                let key = cycleKey(token: token, chargeTimeMs: chargeTimeMs)
                if !prefs.bool(forKey: key) {
                    latest = (chargeTimeMs,
                              Double(intro.priceAmountMicros) / 1_000_000.0,
                              intro.priceCurrencyCode,
                              key)
                }
            }
            chargeTimeMs = next
        }
        return latest
    }

    /// Walks base-plan cycles from `startingAt` up to `now` and returns the latest
    /// unlogged one — which is the cycle the user is currently in.
    ///
    /// Cycles that started and ended before `now` without ever being logged are
    /// naturally overwritten in each iteration, so only the most recent one is returned.
    private func findLatestPendingBaseCycle(
        startingAt start: Int64,
        period: (years: Int, months: Int, days: Int),
        price: Double,
        currency: String,
        token: String,
        purchase: PurchaseRecord,
        now: Int64
    ) -> PendingCycle? {
        var chargeTimeMs = start
        var latest: PendingCycle?

        while chargeTimeMs <= now {
            defer { chargeTimeMs = addPeriod(epochMs: chargeTimeMs, period: period) }
            // Skip purchaseTime — already logged by trackPurchase.
            guard chargeTimeMs > purchase.purchaseTime else { continue }
            let key = cycleKey(token: token, chargeTimeMs: chargeTimeMs)
            if !prefs.bool(forKey: key) {
                latest = (chargeTimeMs, price, currency, key)
            } else {
                print("[AdjustIapTracker] trackRenewal SKIP (already logged): \(key)")
            }
        }
        return latest
    }

    // MARK: - Helpers

    /// Price and currency for the very first charge.
    /// Returns `(0, currency)` for a free trial so the caller can skip tracking.
    private func firstChargePrice(detail: BillingProductDetail) -> (Double, String) {
        if detail.isSubscription() {
            if let intro = detail.introductoryOffer {
                return (Double(intro.priceAmountMicros) / 1_000_000.0, intro.priceCurrencyCode)
            }
            return (
                Double(detail.basePlanPriceAmountMicros) / 1_000_000.0,
                detail.basePlanCurrencyCode ?? "USD"
            )
        } else {
            let micros = detail.oneTimePurchaseOfferDetails?.priceAmountMicros ?? 0
            let currency = detail.oneTimePurchaseOfferDetails?.priceCurrencyCode ?? "USD"
            return (Double(micros) / 1_000_000.0, currency)
        }
    }

    private func sendToAdjust(
        price: Double,
        currency: String,
        purchase: PurchaseRecord,
        productType: String,
        adjustDedupId: String
    ) {
        // TODO: replace with actual Adjust SDK calls when integrated.
        // Example with Adjust iOS SDK:
        //
        // let event = ADJEvent(eventToken: eventToken)
        // event?.setRevenue(price, currency: currency)
        // event?.setProductId(purchase.productId)
        // event?.setTransactionId(purchase.orderId ?? purchase.purchaseToken)
        // event?.setDeduplicationId(adjustDedupId)
        // event?.addCallbackParameter("product_type", value: productType)
        // Adjust.trackEvent(event)
        //
        // iOS: use verifyAndTrackAppStorePurchase instead of verifyAndTrackPlayStorePurchase.

        print("[AdjustIapTracker] TRACKED | price=\(price) \(currency)" +
              " | productId=\(purchase.productId)" +
              " | productType=\(productType)" +
              " | orderId=\(purchase.orderId ?? "")" +
              " | dedupId=\(adjustDedupId)" +
              " | purchaseTime=\(purchase.purchaseTime)")
    }

    /// Parses an ISO 8601 billing period string into `(years, months, days)`.
    private func parsePeriod(_ billingPeriod: String) -> (years: Int, months: Int, days: Int)? {
        let pattern = #"^P(?:(\d+)Y)?(?:(\d+)M)?(?:(\d+)W)?(?:(\d+)D)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: billingPeriod,
                range: NSRange(billingPeriod.startIndex..., in: billingPeriod))
        else {
            print("[AdjustIapTracker] Failed to parse billingPeriod: \(billingPeriod)")
            return nil
        }

        func group(_ i: Int) -> Int {
            guard let range = Range(match.range(at: i), in: billingPeriod) else { return 0 }
            return Int(billingPeriod[range]) ?? 0
        }

        return (group(1), group(2), group(3) * 7 + group(4))
    }

    private func addPeriod(epochMs: Int64, period: (years: Int, months: Int, days: Int)) -> Int64 {
        var components = DateComponents()
        if period.years  != 0 { components.year  = period.years }
        if period.months != 0 { components.month = period.months }
        if period.days   != 0 { components.day   = period.days }
        let date = Date(timeIntervalSince1970: Double(epochMs) / 1000.0)
        let newDate = Calendar(identifier: .gregorian).date(byAdding: components, to: date) ?? date
        return Int64(newDate.timeIntervalSince1970 * 1000)
    }

    private func cycleKey(token: String, chargeTimeMs: Int64) -> String {
        "cycle_\(token)_\(chargeTimeMs)"
    }
}
