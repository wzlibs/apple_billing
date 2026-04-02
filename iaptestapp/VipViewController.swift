import UIKit

class VipViewController: UIViewController {

    private let purchase: PurchaseRecord
    private let detail: BillingProductDetail?
    private let billingLibrary: BillingLibrary

    init(purchase: PurchaseRecord, detail: BillingProductDetail?, billingLibrary: BillingLibrary) {
        self.purchase       = purchase
        self.detail         = detail
        self.billingLibrary = billingLibrary
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - UI

    private let scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private let contentStack: UIStackView = {
        let sv = UIStackView()
        sv.axis      = .vertical
        sv.spacing   = 16
        sv.alignment = .fill
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "VIP"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Quay lại",
            style: .plain,
            target: self,
            action: #selector(didTapBack)
        )

        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 24),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -24),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40)
        ])

        buildUI()
    }

    // MARK: - Actions

    @objc private func didTapBack() {
        navigationController?.popViewController(animated: true)
    }

    @objc private func didTapCancel() {
        Task { await billingLibrary.showManageSubscriptions() }
    }

    // MARK: - Build UI

    private func buildUI() {
        contentStack.addArrangedSubview(makeBadgeCard())
        contentStack.addArrangedSubview(makeReportCard())
        contentStack.addArrangedSubview(makeCancelButton())
    }

    /// Banner ⭐️ VIP
    private func makeBadgeCard() -> UIView {
        let card = makeCard(borderColor: .systemYellow)
        card.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.12)

        let icon = makeLabel("⭐️", font: .systemFont(ofSize: 48), alignment: .center)
        let title = makeLabel("Bạn đang là thành viên VIP", font: .systemFont(ofSize: 20, weight: .bold), alignment: .center)
        title.numberOfLines = 0

        let stack = vstack([icon, title], spacing: 8)
        embed(stack, in: card, insets: UIEdgeInsets(top: 28, left: 16, bottom: 28, right: 16))
        return card
    }

    /// Card thông tin gói
    private func makeReportCard() -> UIView {
        let card = makeCard(borderColor: .separator)

        let header = makeLabel("Thông tin gói đang dùng", font: .systemFont(ofSize: 13, weight: .semibold), color: .secondaryLabel)

        var rows: [UIView] = [header]

        let planName = detail?.name ?? purchase.productId
        rows.append(makeRow(icon: "📦", label: "Gói", value: planName))

        if let detail {
            let price   = detail.basePlanFormattedPrice ?? "-"
            let period  = detail.subscriptionPeriod.map { humanPeriod($0) } ?? "-"
            rows.append(makeRow(icon: "💰", label: "Giá", value: "\(price) / \(period)"))

            if let intro = detail.introductoryOffer {
                switch intro.paymentMode {
                case .freeTrial:
                    rows.append(makeRow(icon: "🎁", label: "Ưu đãi", value: "Dùng thử miễn phí \(humanPeriod(intro.billingPeriod))"))
                case .payUpFront, .payAsYouGo:
                    rows.append(makeRow(icon: "🎁", label: "Ưu đãi", value: "\(intro.formattedPrice) trong \(humanPeriod(intro.billingPeriod))"))
                }
            }
        }

        let startDate = Date(timeIntervalSince1970: Double(purchase.purchaseTime) / 1000.0)
        rows.append(makeRow(icon: "📅", label: "Ngày mua", value: formatDate(startDate)))
        rows.append(makeRow(icon: "🔄", label: "Gia hạn tiếp theo", value: expirationDateString()))

        let stack = vstack(rows, spacing: 14)
        embed(stack, in: card, insets: UIEdgeInsets(top: 20, left: 16, bottom: 20, right: 16))
        return card
    }

    // MARK: - Helpers: UI factories

    private func makeCancelButton() -> UIView {
        let btn = UIButton(type: .system)
        btn.setTitle("Huỷ đăng ký", for: .normal)
        btn.setTitleColor(.systemRed, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        btn.addTarget(self, action: #selector(didTapCancel), for: .touchUpInside)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return btn
    }

    private func makeCard(borderColor: UIColor) -> UIView {
        let v = UIView()
        v.backgroundColor = .secondarySystemGroupedBackground
        v.layer.cornerRadius = 16
        v.layer.borderWidth  = 1
        v.layer.borderColor  = borderColor.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    private func makeRow(icon: String, label: String, value: String) -> UIView {
        let iconLbl  = makeLabel(icon, font: .systemFont(ofSize: 17))
        iconLbl.setContentHuggingPriority(.required, for: .horizontal)

        let keyLbl   = makeLabel(label, font: .systemFont(ofSize: 15), color: .secondaryLabel)
        keyLbl.setContentHuggingPriority(.required, for: .horizontal)

        let valueLbl = makeLabel(value, font: .systemFont(ofSize: 15, weight: .medium))
        valueLbl.numberOfLines = 0
        valueLbl.textAlignment = .right

        let row = UIStackView(arrangedSubviews: [iconLbl, keyLbl, valueLbl])
        row.axis    = .horizontal
        row.spacing = 8
        row.alignment = .center
        return row
    }

    private func makeLabel(_ text: String,
                           font: UIFont,
                           color: UIColor = .label,
                           alignment: NSTextAlignment = .natural) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = font
        l.textColor = color
        l.textAlignment = alignment
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func vstack(_ views: [UIView], spacing: CGFloat) -> UIStackView {
        let sv = UIStackView(arrangedSubviews: views)
        sv.axis    = .vertical
        sv.spacing = spacing
        return sv
    }

    private func embed(_ child: UIView, in parent: UIView, insets: UIEdgeInsets) {
        parent.addSubview(child)
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: insets.top),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: insets.left),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -insets.right),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -insets.bottom)
        ])
    }

    // MARK: - Helpers: date / period logic

    /// Uses the actual expirationDate from StoreKit — correct in both sandbox and production.
    private func expirationDateString() -> String {
        guard let expirationTime = purchase.expirationTime else { return "-" }
        return formatDate(Date(timeIntervalSince1970: Double(expirationTime) / 1000.0))
    }

    private func nextRenewalDateString() -> String {
        guard let detail,
              let periodStr = detail.subscriptionPeriod,
              let period = parsePeriod(periodStr) else { return "-" }

        var chargeTime = Date(timeIntervalSince1970: Double(purchase.purchaseTime) / 1000.0)
        let now = Date()

        // Advance past intro window
        if let intro = detail.introductoryOffer,
           let introPeriod = parsePeriod(intro.billingPeriod) {
            for _ in 0..<intro.billingCycleCount {
                let next = addPeriod(to: chargeTime, period: introPeriod)
                if next > now { break }
                chargeTime = next
            }
            if chargeTime <= now { chargeTime = addPeriod(to: chargeTime, period: introPeriod) }
        }

        // Advance base cycles until next > now
        while chargeTime <= now {
            chargeTime = addPeriod(to: chargeTime, period: period)
        }

        return formatDate(chargeTime)
    }

    private func parsePeriod(_ s: String) -> (years: Int, months: Int, days: Int)? {
        let pattern = #"^P(?:(\d+)Y)?(?:(\d+)M)?(?:(\d+)W)?(?:(\d+)D)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
        else { return nil }
        func g(_ i: Int) -> Int {
            guard let r = Range(m.range(at: i), in: s) else { return 0 }
            return Int(s[r]) ?? 0
        }
        return (g(1), g(2), g(3) * 7 + g(4))
    }

    private func addPeriod(to date: Date, period: (years: Int, months: Int, days: Int)) -> Date {
        var c = DateComponents()
        if period.years  != 0 { c.year  = period.years  }
        if period.months != 0 { c.month = period.months }
        if period.days   != 0 { c.day   = period.days   }
        return Calendar(identifier: .gregorian).date(byAdding: c, to: date) ?? date
    }

    private func humanPeriod(_ iso: String) -> String {
        guard let p = parsePeriod(iso) else { return iso }
        if p.years  > 0 { return "\(p.years) năm" }
        if p.months > 0 { return "\(p.months) tháng" }
        if p.days   > 0 { return "\(p.days) ngày" }
        return iso
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        f.locale = Locale(identifier: "vi_VN")
        return f.string(from: date)
    }
}
