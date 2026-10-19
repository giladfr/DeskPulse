import Combine
import Foundation

/// Checks price alerts on its own schedule, so they fire whatever is on screen,
/// including in the situation layout, which hides the stock card. While the card is
/// open its quotes are checked as they arrive and the symbols it already refreshes
/// are not fetched twice.
@MainActor
final class PriceAlertMonitor {
    /// True while the stock card is on the dashboard, refreshing the watchlist itself.
    var isStockCardVisible: () -> Bool = { false }

    private let settings: AppSettings
    private var loop: Task<Void, Never>?
    private var observation: AnyCancellable?

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Runs the background checks whenever there is at least one alert.
    func start() {
        guard observation == nil else { return }
        observation = settings.$priceAlerts.sink { [weak self] alerts in
            self?.setRunning(!alerts.isEmpty)
        }
    }

    /// Notifies about every alert this quote sets off.
    func check(_ quote: MarketQuote) {
        let today = PriceAlertClock.today()
        for alert in settings.firePriceAlerts(for: quote, today: today) {
            Notifier.post(
                id: "price-alert-\(alert.id.uuidString)-\(today)",
                title: alert.summary,
                body: String(
                    format: "%@ is at %.2f (%+.2f%% today)",
                    quote.symbol, quote.price, quote.dayChangePercent
                )
            )
        }
    }

    private func setRunning(_ running: Bool) {
        if running, loop == nil {
            Notifier.setUp()
            loop = Task { [weak self] in await self?.run() }
        } else if !running {
            loop?.cancel()
            loop = nil
        }
    }

    private func run() async {
        while !Task.isCancelled {
            let entries = symbolsToFetch()
            let quotes = entries.isEmpty ? [] : Array(await MarketData.fetchQuotes(entries).quotes.values)
            for quote in quotes { check(quote) }
            // Every 30 seconds while a market is trading (or might be: pre-market and
            // after-hours prices move too), every 5 minutes when all are idle.
            let now = Date()
            let marketIsQuiet = !quotes.isEmpty && quotes.allSatisfy {
                !$0.isTrading(at: now) && $0.extendedChange == nil
            }
            try? await Task.sleep(for: .seconds(marketIsQuiet ? 300 : 30))
        }
    }

    private func symbolsToFetch() -> [WatchedSymbol] {
        let watched = Dictionary(
            settings.watchlist.map { ($0.symbol, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let covered = isStockCardVisible() ? Set(watched.keys) : []
        return Set(settings.priceAlerts.map(\.symbol))
            .subtracting(covered)
            .sorted()
            .map { watched[$0] ?? WatchedSymbol(symbol: $0) }
    }
}
