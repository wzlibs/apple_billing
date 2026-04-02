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

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "IAP Test"
        view.backgroundColor = .systemGroupedBackground

        setupUI()
        Task { await loadProducts() }
    }

    // MARK: - Setup

    private func setupUI() {
        view.addSubview(statusLabel)
        view.addSubview(tableView)

        tableView.dataSource = self
        tableView.delegate   = self

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            tableView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    // MARK: - IAP

    @MainActor
    private func loadProducts() async {
        let connectionResult = await billingLibrary.connect()
        guard connectionResult == .connected else {
            statusLabel.text = "Billing connection failed."
            return
        }

        let result = await billingLibrary.queryProductDetailsAndPurchases(products: products)
        productDetails = result.productDetails.sorted { $0.productId < $1.productId }
        statusLabel.text = "Found \(productDetails.count) product(s)"
        tableView.reloadData()
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
}
