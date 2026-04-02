//
//  ViewController.swift
//  iaptestapp
//
//  Created by Phạm Văn Nam on 1/4/26.
//

import UIKit

class ViewController: UIViewController {

    private let billingLibrary: BillingLibrary = AppStoreBillingLibrary()

    private let products: [BillingProduct] = [
        BillingProduct(productId: "premium_monthly",       type: .subs),
        BillingProduct(productId: "trial_weekly_premium",  type: .subs),
        BillingProduct(productId: "premium_yearly",        type: .subs),
        BillingProduct(productId: "premium_weekly",        type: .subs),
        BillingProduct(productId: "yearly_discount",       type: .subs),
        BillingProduct(productId: "a01_premium_user_year", type: .subs)
    ]

    private var productDetails: [BillingProductDetail] = []
    private var selectedIndex: Int? = nil
    private var isFirstLoad = true
    private var isNavigatingToVip = false

    // MARK: - UI

    private let tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        return tv
    }()

    private let statusLabel: UILabel = {
        let lbl = UILabel()
        lbl.text = "Loading products..."
        lbl.textAlignment = .center
        lbl.font = UIFont.systemFont(ofSize: 15, weight: .regular)
        lbl.textColor = .secondaryLabel
        lbl.translatesAutoresizingMaskIntoConstraints = false
        return lbl
    }()

    private let buyButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Mua ngay"
        config.cornerStyle = .large
        config.baseForegroundColor = .white
        config.baseBackgroundColor = .systemBlue
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.isEnabled = false
        btn.alpha = 0.5
        return btn
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "IAP Test"
        view.backgroundColor = .systemGroupedBackground

        setupUI()
        billingLibrary.setPurchaseUpdateListener { [weak self] update in
            guard let self else { return }
            switch update {
            case .succeeded(let items):
                guard let item = items.first else { return }
                self.navigateToVip(purchase: item.record, detail: item.productDetail)
            case .alreadyOwned:
                let alert = UIAlertController(
                    title: "Đã đăng ký",
                    message: "Bạn đang có gói đăng ký active.",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(alert, animated: true)
            default:
                break
            }
        }
        Task { await loadProducts(navigateIfVip: true) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !isFirstLoad else { isFirstLoad = false; return }
        isNavigatingToVip = false
        Task { await loadProducts(navigateIfVip: false) }
    }

    // MARK: - Setup

    private func setupUI() {
        view.addSubview(statusLabel)
        view.addSubview(tableView)
        view.addSubview(buyButton)

        tableView.dataSource = self
        tableView.delegate   = self

        buyButton.addTarget(self, action: #selector(didTapBuy), for: .touchUpInside)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            tableView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: buyButton.topAnchor, constant: -8),

            buyButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            buyButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            buyButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
    }

    @objc private func didTapBuy() {
        guard let index = selectedIndex, index < productDetails.count else { return }
        billingLibrary.purchase(product: productDetails[index])
    }

    // MARK: - IAP

    @MainActor
    private func loadProducts(navigateIfVip: Bool) async {
        let connectionResult = await billingLibrary.connect()
        guard connectionResult == .connected else {
            statusLabel.text = "Billing connection failed."
            return
        }

        let result = await billingLibrary.queryProductDetailsAndPurchases(products: products)
        productDetails = result.productDetails.sorted { $0.productId < $1.productId }

        if navigateIfVip,
           let activePurchase = result.purchaseRecords.first(where: { $0.isPurchased }),
           let activeDetail = result.productDetails.first(where: { $0.productId == activePurchase.productId }) {
            navigateToVip(purchase: activePurchase, detail: activeDetail)
            return
        }

        statusLabel.text = "Found \(productDetails.count) product(s)"
        tableView.reloadData()
    }

    private func navigateToVip(purchase: PurchaseRecord, detail: BillingProductDetail?) {
        guard !isNavigatingToVip else { return }
        isNavigatingToVip = true
        let vipVC = VipViewController(purchase: purchase, detail: detail, billingLibrary: billingLibrary)
        navigationController?.setViewControllers([self, vipVC], animated: true)
    }
}

// MARK: - UITableViewDataSource

extension ViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        productDetails.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let detail = productDetails[indexPath.row]

        var config = cell.defaultContentConfiguration()
        config.text = detail.name
        config.secondaryText = buildSubtitle(for: detail)
        config.textProperties.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        config.secondaryTextProperties.font = UIFont.systemFont(ofSize: 13)
        config.secondaryTextProperties.color = .secondaryLabel
        config.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = config
        cell.accessoryType = (indexPath.row == selectedIndex) ? .checkmark : .none
        return cell
    }

    private func buildSubtitle(for detail: BillingProductDetail) -> String {
        var lines: [String] = []
        lines.append("ID: \(detail.productId)")

        if detail.isSubscription() {
            let price = detail.basePlanFormattedPrice ?? "-"
            let period = detail.subscriptionPeriod ?? "-"
            lines.append("Price: \(price) / \(period)")

            if let offer = detail.introductoryOffer {
                switch offer.paymentMode {
                case .freeTrial:
                    lines.append("Intro offer: Free trial (\(offer.billingPeriod))")
                case .payUpFront, .payAsYouGo:
                    lines.append("Intro offer: \(offer.formattedPrice) for \(offer.billingPeriod)")
                }
            }
        } else {
            let price = detail.oneTimePurchaseOfferDetails?.formattedPrice ?? "-"
            lines.append("Price: \(price)")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - UITableViewDelegate

extension ViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        let previous = selectedIndex
        selectedIndex = indexPath.row

        var toReload = [indexPath]
        if let prev = previous, prev != indexPath.row {
            toReload.append(IndexPath(row: prev, section: 0))
        }
        tableView.reloadRows(at: toReload, with: .none)

        buyButton.isEnabled = true
        UIView.animate(withDuration: 0.2) { self.buyButton.alpha = 1.0 }
    }
}
