import SwiftUI

/// Prices for the watchlist and market strip (one batched request every 30 seconds),
/// symbol details, and the expanded symbol's chart at the chosen range.
@MainActor
final class StockMarketModel: ObservableObject {
    @Published private(set) var quotes: [String: MarketQuote] = [:]
    @Published private(set) var details: [String: SymbolDetails] = [:]
    @Published private(set) var chart: PriceChart?
    @Published private(set) var unavailable: Set<String> = []
    @Published private(set) var isUpdating = false

    /// Called when Nasdaq (the fallback) reveals which asset class a symbol belongs to.
    var onAssetClass: (String, String) -> Void = { _, _ in }
    /// Called with every fresh quote, e.g. to check price alerts.
    var onQuote: (MarketQuote) -> Void = { _ in }

    /// Their trading hours drive the NYSE and TASE countdowns.
    static let marketHoursSymbols = ["^GSPC", "^TA125.TA"]
    static let shekelRateSymbol = "ILS=X"

    private var watchlist: [WatchedSymbol] = []
    private var strip: [WatchedSymbol] = []
    private var needsShekelRate = false
    private var expanded: String?
    private var range = ChartRange.day
    private var chartFetchedAt: Date?
    private var isRefreshing = false
    private var refreshAgain = false

    func configure(
        watchlist: [WatchedSymbol],
        strip: [WatchedSymbol],
        needsShekelRate: Bool,
        expanded: String?,
        range: ChartRange
    ) {
        let before = Set(trackedEntries.map(\.symbol))
        let chartChanged = expanded != self.expanded || range != self.range
        self.watchlist = watchlist
        self.strip = strip
        self.needsShekelRate = needsShekelRate
        self.expanded = expanded
        self.range = range
        if chartChanged {
            if chart?.symbol != expanded || chart?.range != range { chart = nil }
            chartFetchedAt = nil
        }
        // New symbols or another chart show up right away, not at the next tick.
        if chartChanged || !Set(trackedEntries.map(\.symbol)).subtracting(before).isEmpty {
            Task { await refresh() }
        }
    }

    /// Runs for as long as the card is on screen.
    func run() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(30))
        }
    }

    private var trackedEntries: [WatchedSymbol] {
        var entries = watchlist + strip
        if let expanded { entries.append(WatchedSymbol(symbol: expanded)) }
        if needsShekelRate { entries.append(WatchedSymbol(symbol: Self.shekelRateSymbol)) }
        var seen = Set<String>()
        return entries.filter { seen.insert($0.symbol).inserted }
    }

    func refresh() async {
        guard !isRefreshing else {
            refreshAgain = true
            return
        }
        isRefreshing = true
        isUpdating = true
        let entries = trackedEntries
        let result = await MarketData.fetchQuotes(entries)
        let hours = strip.isEmpty ? [:] : await SymbolDetailsCache.shared.details(for: Self.marketHoursSymbols)

        // A symbol that misses one round keeps its last quote rather than blinking out.
        quotes.merge(result.quotes, uniquingKeysWith: { _, new in new })
        details.merge(result.details.merging(hours, uniquingKeysWith: { _, new in new }),
                      uniquingKeysWith: { _, new in new })
        unavailable = Set(entries.map(\.symbol).filter { quotes[$0] == nil })
        for quote in result.quotes.values { onQuote(quote) }
        for (symbol, assetClass) in result.nasdaqClasses { onAssetClass(symbol, assetClass) }

        if let symbol = expanded,
           chartFetchedAt.map({ Date().timeIntervalSince($0) >= range.refreshSeconds - 1 }) ?? true {
            let range = range
            if let fetched = await fetchChart(symbol, range: range),
               symbol == expanded, range == self.range {
                chart = fetched
                chartFetchedAt = Date()
            }
        }
        isUpdating = false
        isRefreshing = false
        if refreshAgain {
            refreshAgain = false
            await refresh()
        }
    }

    /// Yahoo's chart, or for a US symbol's day chart, Nasdaq's.
    private func fetchChart(_ symbol: String, range: ChartRange) async -> PriceChart? {
        if let result = await YahooFinance.fetchChart(symbol, range: range) {
            details[symbol] = result.details
            await SymbolDetailsCache.shared.store(result.details)
            return result.chart
        }
        guard range == .day, MarketData.isNasdaqSymbol(symbol) else { return nil }
        let assetClass = watchlist.first { $0.symbol == symbol }?.assetClass ?? "stocks"
        guard let nasdaq = await DataService.fetchChart(symbol: symbol, assetClass: assetClass) else { return nil }
        return PriceChart(symbol: symbol, range: .day, points: nasdaq.points, baseline: nasdaq.previousClose)
    }

    /// Shekels per dollar, from the USD/ILS quote.
    var shekelsPerDollar: Double? { quotes[Self.shekelRateSymbol]?.price }

    func currency(of symbol: String) -> String {
        if let currency = details[symbol]?.currency { return currency }
        return symbol.uppercased().hasSuffix(".TA") ? "ILS" : "USD"
    }
}

/// The watchlist as tiles (or a compact ticker on a short card), a strip of indexes,
/// currencies and commodities with NYSE and TASE hours, a portfolio line, and one
/// symbol expanded into a chart with ranges and stats.
struct StocksWidget: View {
    @EnvironmentObject private var dashboard: DashboardModel
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var market = StockMarketModel()

    private var expandedSymbol: String? {
        settings.stockCardShowsChart ? settings.featuredSymbol : nil
    }

    var body: some View {
        GeometryReader { proxy in
            let showsStrip = settings.showsMarketStrip && !settings.marketStrip.isEmpty
                && proxy.size.height >= 140
            let portfolio = portfolioSummary
            let showsPortfolio = portfolio != nil && proxy.size.height >= 165
            VStack(spacing: 6) {
                if showsStrip {
                    MarketStrip(market: market, onSelect: expand)
                }
                if let symbol = expandedSymbol {
                    SymbolDetail(
                        symbol: symbol,
                        market: market,
                        onClose: collapse
                    )
                } else {
                    WatchlistView(market: market, onSelect: expand)
                }
                if showsPortfolio, let portfolio {
                    PortfolioLine(summary: portfolio)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .onAppear {
            let settings = settings
            market.onAssetClass = { symbol, assetClass in
                settings.setAssetClass(assetClass, for: symbol)
            }
            let priceAlerts = dashboard.priceAlerts
            market.onQuote = { quote in priceAlerts.check(quote) }
            configureMarket()
        }
        .onChange(of: settings.watchlist) { _, _ in configureMarket() }
        .onChange(of: settings.marketStrip) { _, _ in configureMarket() }
        .onChange(of: settings.showsMarketStrip) { _, _ in configureMarket() }
        .onChange(of: settings.featuredSymbol) { _, _ in configureMarket() }
        .onChange(of: settings.stockCardShowsChart) { _, _ in configureMarket() }
        .onChange(of: settings.stockChartRange) { _, _ in configureMarket() }
        .task { await market.run() }
    }

    private func configureMarket() {
        market.configure(
            watchlist: settings.watchlist,
            strip: settings.showsMarketStrip ? settings.marketStrip : [],
            needsShekelRate: settings.hasPositions,
            expanded: expandedSymbol,
            range: settings.stockChartRange
        )
    }

    private var portfolioSummary: PortfolioSummary? {
        guard settings.hasPositions else { return nil }
        let positions = settings.watchlist.compactMap { entry -> (entry: WatchedSymbol, quote: MarketQuote, currency: String)? in
            guard entry.shares != nil, let quote = market.quotes[entry.symbol] else { return nil }
            return (entry, quote, market.currency(of: entry.symbol))
        }
        return PortfolioSummary.make(positions: positions, shekelsPerDollar: market.shekelsPerDollar)
    }

    private func expand(_ symbol: String) {
        withAnimation(.snappy(duration: 0.3)) {
            settings.featuredSymbol = symbol
            settings.stockCardShowsChart = true
        }
    }

    private func collapse() {
        withAnimation(.snappy(duration: 0.3)) {
            settings.stockCardShowsChart = false
        }
    }
}

// MARK: - Formatting

enum PriceText {
    /// Exchange rates get four decimals; everything else two, grouped.
    static func price(_ value: Double, details: SymbolDetails? = nil) -> String {
        let decimals = details?.instrumentType == "CURRENCY" || abs(value) < 1 ? 4 : 2
        return value.formatted(.number.precision(.fractionLength(decimals)))
    }

    static func change(_ value: Double, details: SymbolDetails? = nil) -> String {
        let text = price(abs(value), details: details)
        return (value < 0 ? "−" : "+") + text
    }

    static func percent(_ value: Double) -> String {
        (value < 0 ? "−" : "+") + abs(value).formatted(.number.precision(.fractionLength(2))) + "%"
    }

    /// "$1,234", "−₪5,678", "+$12.3K" with `compact`.
    static func money(_ value: Double, symbol: String, signed: Bool = false, compact: Bool = false) -> String {
        let sign = value < 0 ? "−" : (signed ? "+" : "")
        let amount = compact
            ? abs(value).formatted(.number.notation(.compactName).precision(.significantDigits(3)))
            : abs(value).formatted(.number.precision(.fractionLength(0)))
        return sign + symbol + amount
    }

    static func volume(_ value: Double) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(3)))
    }

    /// "S&P 500" for the strip's well-known symbols, else the symbol.
    static func shortName(_ symbol: String) -> String {
        WatchedSymbol.shortNames[symbol] ?? symbol
    }
}

private func accent(for change: Double) -> Color {
    change >= 0 ? .green : .red
}

/// Green while the regular session trades, orange with only pre-market or after-hours
/// trades, grey when closed.
private func statusColor(_ quote: MarketQuote?, now: Date = Date()) -> Color {
    guard let quote else { return .secondary }
    if quote.isTrading(at: now) { return .green }
    if quote.extendedChange != nil { return .orange }
    return .secondary.opacity(0.6)
}

/// "PRE" before New York's open, "AFTER" otherwise.
private func extendedLabel(now: Date = Date()) -> String {
    DataService.tradingSession(at: now) == .premarket && !DataService.isMarketWeekend(now) ? "PRE" : "AFTER"
}

// MARK: - Watchlist

private struct WatchlistView: View {
    @ObservedObject var market: StockMarketModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var dashboard: DashboardModel
    let onSelect: (String) -> Void
    @State private var showsAddSymbol = false
    @State private var alertSymbol: String?
    @State private var positionSymbol: String?

    var body: some View {
        GeometryReader { proxy in
            Group {
                if proxy.size.height < 62 {
                    ticker
                } else if proxy.size.height < 190 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(settings.watchlist) { tile($0, height: proxy.size.height) }
                            addButton(width: 34, height: proxy.size.height)
                        }
                    }
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 136, maximum: 240), spacing: 6)],
                            spacing: 6
                        ) {
                            ForEach(settings.watchlist) { tile($0, height: 96) }
                            addButton(width: nil, height: 96)
                        }
                    }
                }
            }
        }
        .popover(isPresented: Binding(
            get: { alertSymbol != nil },
            set: { if !$0 { alertSymbol = nil } }
        ), arrowEdge: .bottom) {
            if let symbol = alertSymbol {
                PriceAlertForm(symbol: symbol, currentPrice: market.quotes[symbol]?.price) {
                    alertSymbol = nil
                }
                .environmentObject(settings)
            }
        }
        .popover(isPresented: Binding(
            get: { positionSymbol != nil },
            set: { if !$0 { positionSymbol = nil } }
        ), arrowEdge: .bottom) {
            if let symbol = positionSymbol {
                PositionForm(symbol: symbol, currency: market.currency(of: symbol)) {
                    positionSymbol = nil
                }
                .environmentObject(settings)
            }
        }
    }

    /// One line of symbols for very short cards.
    private var ticker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(settings.watchlist) { entry in
                    let quote = market.quotes[entry.symbol]
                    Button { onSelect(entry.symbol) } label: {
                        HStack(spacing: 5) {
                            Text(entry.symbol).font(.system(size: 11, weight: .heavy, design: .rounded))
                            if let quote {
                                Text(PriceText.price(quote.price, details: market.details[entry.symbol]))
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                Text(PriceText.percent(quote.dayChangePercent))
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(accent(for: quote.dayChange))
                                Sparkline(values: quote.sparkline, baseline: quote.previousClose)
                                    .frame(width: 34, height: 14)
                            }
                        }
                        .monospacedDigit()
                    }
                    .buttonStyle(.plain)
                    .contextMenu { menu(for: entry) }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func tile(_ entry: WatchedSymbol, height: CGFloat) -> some View {
        WatchlistTile(
            entry: entry,
            quote: market.quotes[entry.symbol],
            details: market.details[entry.symbol],
            isUnavailable: market.unavailable.contains(entry.symbol),
            hasAlert: settings.priceAlerts.contains { $0.symbol == entry.symbol },
            height: height
        )
        .frame(width: height < 190 ? 148 : nil, height: height)
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture { onSelect(entry.symbol) }
        .help("Show \(entry.symbol)'s chart")
        .contextMenu { menu(for: entry) }
    }

    @ViewBuilder
    private func menu(for entry: WatchedSymbol) -> some View {
        Button("Show chart") { onSelect(entry.symbol) }
        Button("Add price alert…") { alertSymbol = entry.symbol }
        Button(entry.shares == nil ? "Add position…" : "Edit position…") { positionSymbol = entry.symbol }
        Button("Open on Yahoo Finance") { openOnYahoo(entry.symbol, dashboard: dashboard) }
        Divider()
        Button("Remove from watchlist", role: .destructive) {
            settings.removeSymbol(entry.symbol)
        }
        .disabled(settings.watchlist.count <= 1)
    }

    private func addButton(width: CGFloat?, height: CGFloat) -> some View {
        Button {
            showsAddSymbol = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .frame(maxWidth: width ?? .infinity)
                .frame(width: width, height: height)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .help("Add a stock, ETF, index, currency or crypto")
        .popover(isPresented: $showsAddSymbol, arrowEdge: .bottom) {
            AddSymbolForm(title: "Add to watchlist") { symbol, assetClass in
                settings.addSymbol(symbol, assetClass: assetClass)
                showsAddSymbol = false
            }
        }
    }
}

@MainActor
private func openOnYahoo(_ symbol: String, dashboard: DashboardModel) {
    let escaped = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
    if let url = URL(string: "https://finance.yahoo.com/quote/\(escaped)") {
        dashboard.open(url)
    }
}

private struct WatchlistTile: View {
    let entry: WatchedSymbol
    let quote: MarketQuote?
    let details: SymbolDetails?
    let isUnavailable: Bool
    let hasAlert: Bool
    let height: CGFloat

    var body: some View {
        let change = quote?.dayChange ?? 0
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(PriceText.shortName(entry.symbol))
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                if hasAlert {
                    Image(systemName: "bell.fill").font(.system(size: 7)).foregroundStyle(.yellow)
                }
                Spacer(minLength: 2)
                Circle().fill(statusColor(quote)).frame(width: 5, height: 5)
            }
            if height >= 84, let details {
                Text(details.name)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let quote {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(PriceText.price(quote.sessionPrice, details: details))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText(value: quote.sessionPrice))
                        .animation(.snappy, value: quote.sessionPrice)
                    Spacer(minLength: 2)
                    Text(PriceText.percent(quote.dayChangePercent))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(accent(for: change))
                }
                .lineLimit(1)
                if height >= 70 {
                    Sparkline(values: quote.sparkline, baseline: quote.previousClose)
                        .frame(maxHeight: .infinity)
                }
                footer(quote)
            } else {
                Spacer(minLength: 0)
                Text(isUnavailable ? "No quote" : "…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            LinearGradient(
                colors: [accent(for: change).opacity(quote == nil ? 0 : 0.10), Color.white.opacity(0.03)],
                startPoint: .bottom, endPoint: .top
            ),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.07)))
    }

    @ViewBuilder
    private func footer(_ quote: MarketQuote) -> some View {
        if let extended = quote.extendedChangePercent {
            Text("\(extendedLabel()) \(PriceText.price(quote.price, details: details)) \(PriceText.percent(extended))")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.orange)
                .lineLimit(1)
        } else if let shares = entry.shares, let details {
            let symbol = details.currencySymbol
            Text("\(shares.formatted()) sh · \(PriceText.money(shares * quote.dayChange, symbol: symbol, signed: true, compact: true)) today")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// A day's prices as a small line, green above the previous close and red below.
struct Sparkline: View {
    let values: [Double]
    let baseline: Double

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, let low = (values + [baseline]).min(), let high = (values + [baseline]).max()
            else { return }
            let span = max(high - low, abs(high) * 0.0005, 0.0001)
            func y(_ value: Double) -> CGFloat { size.height * (1 - (value - low) / span) }
            let step = size.width / CGFloat(values.count - 1)
            var line = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: CGFloat(index) * step, y: y(value))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            let baseY = y(baseline)
            var base = Path()
            base.move(to: CGPoint(x: 0, y: baseY))
            base.addLine(to: CGPoint(x: size.width, y: baseY))
            context.stroke(base, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 0.7, dash: [2, 3]))
            for (color, rect) in [
                (Color.green, CGRect(x: 0, y: 0, width: size.width, height: baseY)),
                (Color.red, CGRect(x: 0, y: baseY, width: size.width, height: size.height - baseY))
            ] {
                context.drawLayer { layer in
                    layer.clip(to: Path(rect))
                    layer.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Market strip

private struct MarketStrip: View {
    @ObservedObject var market: StockMarketModel
    @EnvironmentObject private var settings: AppSettings
    let onSelect: (String) -> Void

    var body: some View {
        // One scrolling row, so a narrow card scrolls instead of truncating.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: 10) {
                        marketHours("NYSE", symbol: "^GSPC", now: context.date)
                        marketHours("TASE", symbol: "^TA125.TA", now: context.date)
                    }
                }
                Divider().frame(height: 12).opacity(0.3)
                ForEach(settings.marketStrip) { entry in
                    item(entry)
                }
            }
            .fixedSize()
        }
        .frame(height: 18)
        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
        .monospacedDigit()
    }

    private func marketHours(_ name: String, symbol: String, now: Date) -> some View {
        let details = market.details[symbol]
        let status = MarketClock.status(now: now, start: details?.regularStart, end: details?.regularEnd)
        return HStack(spacing: 4) {
            Circle().fill(status.isOpen ? Color.green : Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
            Text(name).fontWeight(.heavy)
            Text(details == nil ? "…" : status.text).foregroundStyle(.secondary)
        }
        .help(status.isOpen ? "\(name) is open" : "\(name) is closed")
    }

    private func item(_ entry: WatchedSymbol) -> some View {
        let quote = market.quotes[entry.symbol]
        return Button { onSelect(entry.symbol) } label: {
            HStack(spacing: 4) {
                Text(PriceText.shortName(entry.symbol)).foregroundStyle(.secondary)
                if let quote {
                    Text(PriceText.price(quote.price, details: market.details[entry.symbol]))
                    Text(PriceText.percent(quote.dayChangePercent))
                        .foregroundStyle(accent(for: quote.dayChange))
                } else {
                    Text("…").foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .help(market.details[entry.symbol]?.name ?? entry.symbol)
    }
}

// MARK: - Portfolio

private struct PortfolioLine: View {
    let summary: PortfolioSummary

    var body: some View {
        HStack(spacing: 10) {
            Label {
                HStack(spacing: 4) {
                    Text(PriceText.money(summary.value, symbol: "$"))
                    if let rate = summary.shekelsPerDollar {
                        Text("≈ \(PriceText.money(summary.value * rate, symbol: "₪"))").foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "briefcase.fill").foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text("Day \(PriceText.money(summary.dayChange, symbol: "$", signed: true)) \(PriceText.percent(summary.dayChangePercent))")
                .foregroundStyle(accent(for: summary.dayChange))
            if let total = summary.totalChange, let percent = summary.totalChangePercent {
                Text("Total \(PriceText.money(total, symbol: "$", signed: true)) \(PriceText.percent(percent))")
                    .foregroundStyle(accent(for: total))
            }
        }
        .font(.system(size: 9.5, weight: .bold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .frame(height: 14)
        .help("Your positions, in dollars; shekel holdings are converted at the USD/ILS rate")
    }
}

// MARK: - Expanded symbol

private struct SymbolDetail: View {
    let symbol: String
    @ObservedObject var market: StockMarketModel
    let onClose: () -> Void
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var dashboard: DashboardModel

    var body: some View {
        GeometryReader { proxy in
            let roomy = proxy.size.height >= 150
            // On a narrow card the range buttons sit on the chart, leaving the header
            // room for the price.
            let narrow = proxy.size.width < 440
            VStack(spacing: 4) {
                header(roomy: roomy, width: proxy.size.width, showsRanges: !narrow)
                Group {
                    if let chart = market.chart, chart.symbol == symbol, chart.range == settings.stockChartRange {
                        PriceGraph(
                            chart: chart,
                            details: market.details[symbol],
                            alertLevels: settings.priceAlerts.filter { $0.symbol == symbol }.compactMap(\.priceLevel)
                        )
                    } else {
                        LoadingState(label: "Loading \(settings.stockChartRange.rawValue) chart…")
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottomLeading) {
                    if narrow {
                        RangePicker(selection: $settings.stockChartRange)
                            .background(Color.black.opacity(0.55), in: Capsule())
                    }
                }
                if roomy {
                    StatsRow(symbol: symbol, market: market)
                }
            }
        }
    }

    private func header(roomy: Bool, width: CGFloat, showsRanges: Bool) -> some View {
        let quote = market.quotes[symbol]
        let details = market.details[symbol]
        return HStack(alignment: .center, spacing: 8) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Color.white.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Back to the watchlist")
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(PriceText.shortName(symbol))
                        .font(.system(size: roomy ? 16 : 13, weight: .black, design: .rounded))
                    Circle().fill(statusColor(quote)).frame(width: 6, height: 6)
                }
                if roomy || width > 520, let details {
                    Text([details.name, details.exchange].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .onTapGesture { openOnYahoo(symbol, dashboard: dashboard) }
            .help("Open \(symbol) on Yahoo Finance")
            Spacer(minLength: 6)
            if let quote {
                VStack(alignment: .trailing, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(PriceText.price(quote.sessionPrice, details: details))
                            .font(.system(size: roomy ? 19 : 15, weight: .semibold, design: .rounded))
                            .contentTransition(.numericText(value: quote.sessionPrice))
                            .animation(.snappy, value: quote.sessionPrice)
                        Text("\(PriceText.change(quote.dayChange, details: details)) \(PriceText.percent(quote.dayChangePercent))")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundStyle(accent(for: quote.dayChange))
                    }
                    if let extended = quote.extendedChange, let percent = quote.extendedChangePercent {
                        Text("\(extendedLabel()) \(PriceText.price(quote.price, details: details)) \(PriceText.change(extended, details: details)) \(PriceText.percent(percent))")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.orange)
                    }
                }
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
            }
            if showsRanges {
                RangePicker(selection: $settings.stockChartRange)
            }
        }
    }
}

private struct RangePicker: View {
    @Binding var selection: ChartRange

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ChartRange.allCases) { range in
                Button {
                    selection = range
                } label: {
                    Text(range.rawValue)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(selection == range ? .black : .secondary)
                        .frame(width: 24, height: 17)
                        .background(selection == range ? Color.white.opacity(0.85) : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.06), in: Capsule())
    }
}

/// Day range and 52-week range as bars with today's price on them, volume, and the
/// position if there is one.
private struct StatsRow: View {
    let symbol: String
    @ObservedObject var market: StockMarketModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let quote = market.quotes[symbol]
        let details = market.details[symbol]
        HStack(spacing: 14) {
            if let details, let quote {
                if let low = details.dayLow, let high = details.dayHigh, high > low {
                    RangeBar(title: "DAY", low: low, high: high, value: quote.sessionPrice, details: details)
                }
                if let low = details.yearLow, let high = details.yearHigh, high > low {
                    RangeBar(title: "52W", low: low, high: high, value: quote.price, details: details)
                }
                if let volume = details.volume, volume > 0 {
                    stat("VOL", PriceText.volume(volume))
                }
            }
            Spacer(minLength: 0)
            if let entry = settings.watchlist.first(where: { $0.symbol == symbol }),
               let shares = entry.shares, let quote {
                let currency = details?.currencySymbol ?? ""
                stat("POSITION", "\(shares.formatted()) · \(PriceText.money(shares * quote.price, symbol: currency))")
                if let cost = entry.averageCost {
                    let gain = shares * (quote.price - cost)
                    stat("GAIN", "\(PriceText.money(gain, symbol: currency, signed: true)) \(PriceText.percent(cost == 0 ? 0 : (quote.price - cost) / cost * 100))")
                        .foregroundStyle(accent(for: gain))
                }
            }
        }
        .frame(height: 22)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 7, weight: .heavy)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 9.5, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .lineLimit(1)
    }
}

private struct RangeBar: View {
    let title: String
    let low: Double
    let high: Double
    let value: Double
    let details: SymbolDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 7, weight: .heavy)).foregroundStyle(.tertiary)
                Text("\(PriceText.price(low, details: details)) – \(PriceText.price(high, details: details))")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                let fraction = min(max((value - low) / (high - low), 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12)).frame(height: 3)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 6, height: 6)
                        .offset(x: proxy.size.width * fraction - 3)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 6)
        }
        .monospacedDigit()
        .frame(width: 118)
        .help("\(title == "DAY" ? "Today's" : "52-week") range")
    }
}

/// Prices over the chosen range, green above the baseline (previous close for one day,
/// the close before the range otherwise) and red below, with price-alert lines and a
/// crosshair that reads out the price and time under the pointer. On the one-day chart,
/// pre-market and after-hours trading sit on shaded bands with a dimmer line, so the
/// regular session stands out.
struct PriceGraph: View {
    let chart: PriceChart
    let details: SymbolDetails?
    var alertLevels: [Double] = []
    @State private var hoverX: CGFloat?

    var body: some View {
        Canvas { context, size in
            guard let layout = Layout(chart: chart, alertLevels: alertLevels, size: size) else { return }
            let baselineY = layout.y(chart.baseline)
            let points = chart.points

            // The regular session at full strength, extended hours dimmed.
            let sessions = layout.sessionBands()
            let parts = [(sessions.regular, 1.0)] + sessions.extended.map { ($0.rect, 0.4) }
            for band in sessions.extended {
                context.fill(Path(band.rect), with: .color(.white.opacity(0.035)))
                let label = context.resolve(
                    Text(band.label)
                        .font(.system(size: 7.5, weight: .heavy, design: .rounded))
                        .foregroundColor(.secondary.opacity(0.8))
                )
                if label.measure(in: size).width + 6 < band.rect.width {
                    context.draw(label, at: CGPoint(x: band.rect.minX + 4, y: size.height - 3), anchor: .bottomLeading)
                }
            }

            var area = Path()
            area.move(to: CGPoint(x: layout.x(0), y: baselineY))
            for index in points.indices {
                area.addLine(to: CGPoint(x: layout.x(index), y: layout.y(points[index].price)))
            }
            area.addLine(to: CGPoint(x: layout.x(points.count - 1), y: baselineY))
            area.closeSubpath()
            let halves = [
                (Color.green, CGRect(x: 0, y: 0, width: size.width, height: baselineY)),
                (Color.red, CGRect(x: 0, y: baselineY, width: size.width, height: size.height - baselineY))
            ]
            for (color, rect) in halves {
                for (part, strength) in parts {
                    context.drawLayer { layer in
                        layer.clip(to: Path(rect))
                        layer.clip(to: Path(part))
                        layer.fill(area, with: .color(color.opacity(0.13 * strength)))
                    }
                }
            }

            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: baselineY))
            baseline.addLine(to: CGPoint(x: size.width, y: baselineY))
            context.stroke(baseline, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            let baselineLabel = context.resolve(
                Text("\(chart.range == .day ? "Prev close" : "\(chart.range.rawValue) ago") \(PriceText.price(chart.baseline, details: details))")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
            )
            let labelAbove = baselineY > 14
            context.draw(
                baselineLabel,
                at: CGPoint(x: 3, y: labelAbove ? baselineY - 2 : baselineY + 2),
                anchor: labelAbove ? .bottomLeading : .topLeading
            )

            // Where the regular session opened, after pre-market trading.
            if chart.range == .day,
               let open = points.firstIndex(where: { $0.session == .regular }), open > 0 {
                var divider = Path()
                divider.move(to: CGPoint(x: layout.x(open), y: 0))
                divider.addLine(to: CGPoint(x: layout.x(open), y: size.height))
                context.stroke(divider, with: .color(.secondary.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }

            for level in layout.visibleAlertLevels {
                let y = layout.y(level)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(.yellow.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                let label = context.resolve(
                    Text("🔔 \(PriceText.price(level, details: details))")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundColor(.yellow)
                )
                context.draw(label, at: CGPoint(x: size.width - 2, y: y - 1), anchor: .bottomTrailing)
            }

            var line = Path()
            for index in points.indices {
                let position = CGPoint(x: layout.x(index), y: layout.y(points[index].price))
                if index == 0 { line.move(to: position) } else { line.addLine(to: position) }
            }
            for (color, rect) in halves {
                for (part, strength) in parts {
                    context.drawLayer { layer in
                        layer.clip(to: Path(rect))
                        layer.clip(to: Path(part))
                        layer.stroke(
                            line,
                            with: .color(color.opacity(strength)),
                            style: StrokeStyle(lineWidth: strength < 1 ? 1.2 : 1.6, lineCap: .round, lineJoin: .round)
                        )
                    }
                }
            }

            if let last = points.last {
                let end = CGPoint(x: layout.x(points.count - 1), y: layout.y(last.price))
                context.fill(
                    Path(ellipseIn: CGRect(x: end.x - 2.5, y: end.y - 2.5, width: 5, height: 5)),
                    with: .color(last.price >= chart.baseline ? .green : .red)
                )
            }

            if let hoverX, let index = layout.nearestIndex(toX: hoverX) {
                let point = points[index]
                let position = CGPoint(x: layout.x(index), y: layout.y(point.price))
                var crosshair = Path()
                crosshair.move(to: CGPoint(x: position.x, y: 0))
                crosshair.addLine(to: CGPoint(x: position.x, y: size.height))
                context.stroke(crosshair, with: .color(.white.opacity(0.35)), lineWidth: 1)
                context.fill(
                    Path(ellipseIn: CGRect(x: position.x - 3, y: position.y - 3, width: 6, height: 6)),
                    with: .color(.white)
                )
                let change = chart.baseline == 0 ? 0 : (point.price - chart.baseline) / chart.baseline * 100
                let label = context.resolve(
                    Text("\(PriceText.price(point.price, details: details))  \(PriceText.percent(change))  \(timeLabel(point.timestamp))\(sessionTag(point.session))")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                )
                let textSize = label.measure(in: size)
                let x = min(max(position.x - textSize.width / 2, 2), size.width - textSize.width - 2)
                let box = CGRect(x: x - 4, y: 1, width: textSize.width + 8, height: textSize.height + 4)
                context.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(.black.opacity(0.75)))
                context.draw(label, at: CGPoint(x: x, y: 3), anchor: .topLeading)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hoverX = location.x
            case .ended: hoverX = nil
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(chart.range.rawValue) chart of \(chart.symbol)")
        .accessibilityValue(chart.points.last.map { "Last \(PriceText.price($0.price)), baseline \(PriceText.price(chart.baseline))" } ?? "")
    }

    private func sessionTag(_ session: TradingSession) -> String {
        switch session {
        case .premarket: "  PRE"
        case .afterHours: "  AFTER"
        case .regular: ""
        }
    }

    private func timeLabel(_ date: Date) -> String {
        switch chart.range {
        case .day: date.formatted(date: .omitted, time: .shortened)
        case .fiveDays, .month: date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        case .sixMonths, .year: date.formatted(.dateTime.month(.abbreviated).day().year())
        }
    }

    struct Layout {
        let chart: PriceChart
        let size: CGSize
        let minimum: Double
        let maximum: Double
        let visibleAlertLevels: [Double]
        private let firstTime: TimeInterval
        private let timeRange: TimeInterval

        init?(chart: PriceChart, alertLevels: [Double], size: CGSize) {
            let prices = chart.points.map(\.price)
            guard chart.points.count > 1,
                  let first = chart.points.first?.timestamp.timeIntervalSince1970,
                  let last = chart.points.last?.timestamp.timeIntervalSince1970,
                  let low = (prices + [chart.baseline]).min(),
                  let high = (prices + [chart.baseline]).max()
            else { return nil }
            // Alert lines near the prices stretch the scale; far-off ones are left out.
            let span = max(high - low, 0.0001)
            let levels = alertLevels.filter { $0 >= low - span * 0.5 && $0 <= high + span * 0.5 }
            let lower = min(low, levels.min() ?? low)
            let upper = max(high, levels.max() ?? high)
            let range = max(upper - lower, abs(upper) * 0.0005, 0.0001)
            self.chart = chart
            self.size = size
            visibleAlertLevels = levels
            minimum = lower - range * 0.08
            maximum = upper + range * 0.08
            firstTime = first
            timeRange = max(last - first, 1)
        }

        /// Time-proportional for one day; evenly spaced otherwise, so nights and
        /// weekends don't leave gaps.
        func x(_ index: Int) -> CGFloat {
            if chart.range == .day {
                return size.width * (chart.points[index].timestamp.timeIntervalSince1970 - firstTime) / timeRange
            }
            return size.width * CGFloat(index) / CGFloat(max(chart.points.count - 1, 1))
        }

        func y(_ price: Double) -> CGFloat {
            size.height * (1 - (price - minimum) / (maximum - minimum))
        }

        struct ExtendedBand {
            let rect: CGRect
            let label: String
        }

        /// The regular session's stretch of the one-day chart, and the pre-market and
        /// after-hours stretches either side of it.
        func sessionBands() -> (regular: CGRect, extended: [ExtendedBand]) {
            let full = CGRect(origin: .zero, size: size)
            let points = chart.points
            guard chart.range == .day, points.contains(where: { $0.session != .regular }) else { return (full, []) }
            guard let open = points.firstIndex(where: { $0.session == .regular }) else {
                let label = points.first?.session == .afterHours ? "AFTER HOURS" : "PRE-MARKET"
                return (.zero, [ExtendedBand(rect: full, label: label)])
            }
            let start = open > 0 ? x(open) : 0
            let close = points[open...].firstIndex { $0.session == .afterHours }
            let end = close.map { x($0) } ?? size.width
            var extended: [ExtendedBand] = []
            if start > 0 {
                extended.append(ExtendedBand(rect: CGRect(x: 0, y: 0, width: start, height: size.height), label: "PRE"))
            }
            if end < size.width {
                extended.append(ExtendedBand(rect: CGRect(x: end, y: 0, width: size.width - end, height: size.height), label: "AFTER"))
            }
            return (CGRect(x: start, y: 0, width: end - start, height: size.height), extended)
        }

        func nearestIndex(toX target: CGFloat) -> Int? {
            chart.points.indices.min { abs(x($0) - target) < abs(x($1) - target) }
        }
    }
}

// MARK: - Forms

enum PriceAlertClock {
    /// The New York trading day, so daily-move alerts reset with the market.
    @MainActor
    static func today() -> String {
        CachedDateFormatter.string(from: Date(), format: "yyyy-MM-dd", timeZone: "America/New_York")
    }
}

/// Creates a price alert for one symbol, prefilled around the current price.
struct PriceAlertForm: View {
    enum Kind: String, CaseIterable, Identifiable {
        case above = "Rises above"
        case below = "Falls below"
        case move = "Moves ± % in a day"
        var id: String { rawValue }
    }

    @EnvironmentObject private var settings: AppSettings
    let symbol: String
    let currentPrice: Double?
    var onDone: () -> Void = {}
    @State private var kind = Kind.above
    @State private var value: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Alert for \(symbol)").font(.headline)
            if let currentPrice {
                Text("Now \(currentPrice, format: .number.precision(.fractionLength(2)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("When it", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            TextField(kind == .move ? "Percent, e.g. 3" : "Price", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .onSubmit(add)
            HStack {
                Spacer()
                Button("Cancel", action: onDone)
                Button("Add alert", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled((value ?? 0) <= 0)
            }
            Text("You'll get a macOS notification, even when the stock card is hidden.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { suggestValue() }
        .onChange(of: kind) { _, _ in suggestValue() }
    }

    private func suggestValue() {
        switch kind {
        case .above: value = currentPrice.map { ($0 * 1.02 * 100).rounded() / 100 }
        case .below: value = currentPrice.map { ($0 * 0.98 * 100).rounded() / 100 }
        case .move: value = 3
        }
    }

    private func add() {
        guard let value, value > 0 else { return }
        let condition: PriceAlert.Condition = switch kind {
        case .above: .above(value)
        case .below: .below(value)
        case .move: .dailyMove(value)
        }
        settings.priceAlerts.append(PriceAlert(symbol: symbol, condition: condition))
        Notifier.setUp()
        onDone()
    }
}

/// Shares and average cost for one watched symbol.
struct PositionForm: View {
    @EnvironmentObject private var settings: AppSettings
    let symbol: String
    let currency: String
    var onDone: () -> Void = {}
    @State private var shares: Double?
    @State private var averageCost: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Position in \(symbol)").font(.headline)
            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Text("Shares").foregroundStyle(.secondary)
                    TextField("e.g. 25", value: $shares, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                }
                GridRow {
                    Text("Average cost").foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("per share", value: $averageCost, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                        Text(currency).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                if settings.watchlist.first(where: { $0.symbol == symbol })?.shares != nil {
                    Button("Remove position", role: .destructive) {
                        settings.setPosition(symbol, shares: nil, averageCost: nil)
                        onDone()
                    }
                }
                Spacer()
                Button("Cancel", action: onDone)
                Button("Save") {
                    settings.setPosition(symbol, shares: shares, averageCost: averageCost)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .disabled((shares ?? 0) == 0)
            }
            Text("Used for the portfolio line: today's and total gain, in dollars and shekels. Kept on this Mac only.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 300)
        .onAppear {
            let entry = settings.watchlist.first { $0.symbol == symbol }
            shares = entry?.shares
            averageCost = entry?.averageCost
        }
    }
}

/// Finds symbols by name or ticker (Yahoo search) and checks a typed symbol has a
/// quote before adding it, so typos don't become dead tiles.
struct AddSymbolForm: View {
    var title = "Add to watchlist"
    let onAdd: (String, String?) -> Void
    @State private var text = ""
    @State private var results: [SymbolSearchResult] = []
    @State private var isChecking = false
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                Text(title).font(.headline)
            }
            HStack {
                // A Settings form would turn a titled field into a label and a box.
                TextField("Symbol", text: $text, prompt: Text("Name or symbol: Teva, MSFT, ^GSPC, ILS=X"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add(text) }
                    .frame(width: 240)
                Button("Add") { add(text) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isChecking || WatchedSymbol.normalized(text) == nil)
            }
            if isChecking {
                ProgressView().controlSize(.small)
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { result in
                        Button { add(result.symbol) } label: {
                            HStack(spacing: 8) {
                                Text(result.symbol)
                                    .font(.system(.caption, design: .monospaced).weight(.bold))
                                    .frame(width: 84, alignment: .leading)
                                Text(result.name).font(.caption).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(result.exchange).font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 320)
            }
            Text("Stocks and ETFs (Tel Aviv shares end in .TA), indexes like ^GSPC, currencies like ILS=X, crypto like BTC-USD.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .onChange(of: text) { _, query in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                let found = await YahooFinance.search(query)
                guard !Task.isCancelled else { return }
                results = found
            }
        }
    }

    private func add(_ raw: String) {
        guard let symbol = WatchedSymbol.normalized(raw), !isChecking else { return }
        isChecking = true
        error = nil
        Task {
            let result = await MarketData.fetchQuotes([WatchedSymbol(symbol: symbol)])
            isChecking = false
            guard result.quotes[symbol] != nil else {
                error = "No quote found for \(symbol)."
                return
            }
            onAdd(symbol, result.nasdaqClasses[symbol])
            text = ""
            results = []
        }
    }
}
