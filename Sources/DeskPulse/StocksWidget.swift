import SwiftUI

/// Quotes for the watchlist and the featured symbol's intraday chart, refreshed on a
/// schedule that speeds up for the featured symbol and slows down when markets close.
@MainActor
final class StockMarketModel: ObservableObject {
    @Published private(set) var quotes: [String: StockQuote] = [:]
    @Published private(set) var charts: [String: StockSessionChart] = [:]
    @Published private(set) var unavailable: Set<String> = []
    @Published private(set) var isUpdating = false

    /// Called when Nasdaq reveals which asset class a symbol belongs to.
    var onAssetClass: (String, String) -> Void = { _, _ in }

    private var watchlist: [WatchedSymbol] = []
    private var featured = ""
    private var tick = 0
    private var featuredTask: Task<Void, Never>?

    func configure(watchlist: [WatchedSymbol], featured: String) {
        let featuredChanged = featured != self.featured
        let added = Set(watchlist.map(\.symbol)).subtracting(self.watchlist.map(\.symbol))
        self.watchlist = watchlist
        self.featured = featured
        // Switching or adding shows data right away instead of at the next tick.
        if featuredChanged {
            featuredTask?.cancel()
            featuredTask = Task { await refreshFeatured() }
        }
        if !added.isEmpty {
            Task { await refreshQuotes(watchlist.filter { added.contains($0.symbol) }) }
        }
    }

    /// Runs for as long as the card is on screen.
    func run() async {
        await refreshQuotes(watchlist)
        while !Task.isCancelled {
            let marketIsQuiet = quotes[featured].map {
                $0.marketStatus.localizedCaseInsensitiveContains("closed")
            } ?? false
            try? await Task.sleep(for: .seconds(marketIsQuiet ? 60 : 10))
            guard !Task.isCancelled else { break }
            tick += 1
            await refreshFeatured()
            if marketIsQuiet || tick % 3 == 0 {
                await refreshQuotes(watchlist.filter { $0.symbol != featured })
            }
        }
    }

    private func refreshFeatured() async {
        guard let entry = watchlist.first(where: { $0.symbol == featured }) else { return }
        isUpdating = true
        defer { isUpdating = false }
        guard let result = await DataService.fetchQuote(symbol: entry.symbol, assetClass: entry.assetClass)
        else {
            if quotes[entry.symbol] == nil { unavailable.insert(entry.symbol) }
            return
        }
        store(result.quote, assetClass: result.assetClass, for: entry)
        if let chart = await DataService.fetchChart(symbol: entry.symbol, assetClass: result.assetClass) {
            charts[entry.symbol] = chart
        }
    }

    private func refreshQuotes(_ entries: [WatchedSymbol]) async {
        guard !entries.isEmpty else { return }
        let results = await withTaskGroup(
            of: (WatchedSymbol, (quote: StockQuote, assetClass: String)?).self
        ) { group in
            for entry in entries {
                group.addTask {
                    (entry, await DataService.fetchQuote(symbol: entry.symbol, assetClass: entry.assetClass))
                }
            }
            var results: [(WatchedSymbol, (quote: StockQuote, assetClass: String)?)] = []
            for await result in group { results.append(result) }
            return results
        }
        for (entry, result) in results {
            if let result {
                store(result.quote, assetClass: result.assetClass, for: entry)
            } else if quotes[entry.symbol] == nil {
                unavailable.insert(entry.symbol)
            }
        }
    }

    private func store(_ quote: StockQuote, assetClass: String, for entry: WatchedSymbol) {
        quotes[entry.symbol] = quote
        unavailable.remove(entry.symbol)
        if entry.assetClass != assetClass {
            onAssetClass(entry.symbol, assetClass)
        }
    }
}

struct StocksWidget: View {
    @EnvironmentObject private var dashboard: DashboardModel
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var market = StockMarketModel()

    private var featured: String { settings.featuredSymbol }

    var body: some View {
        GeometryReader { proxy in
            let showsWatchlist = proxy.size.height >= 140 && settings.watchlist.count > 1
            VStack(spacing: 6) {
                featuredSection(width: proxy.size.width)
                if showsWatchlist {
                    WatchlistStrip(market: market)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                if let quote = market.quotes[featured] {
                    RadialGradient(
                        colors: [(quote.change >= 0 ? Color.green : .red).opacity(0.10), .clear],
                        center: .bottomLeading,
                        startRadius: 8,
                        endRadius: 320
                    )
                }
            }
        }
        .onAppear {
            let settings = settings
            market.onAssetClass = { symbol, assetClass in
                settings.setAssetClass(assetClass, for: symbol)
            }
            market.configure(watchlist: settings.watchlist, featured: featured)
        }
        .onChange(of: settings.watchlist) { _, watchlist in
            market.configure(watchlist: watchlist, featured: featured)
        }
        .onChange(of: settings.featuredSymbol) { _, symbol in
            market.configure(watchlist: settings.watchlist, featured: symbol)
        }
        .task { await market.run() }
    }

    @ViewBuilder
    private func featuredSection(width: CGFloat) -> some View {
        if let quote = market.quotes[featured] {
            VStack(spacing: 4) {
                FeaturedQuoteHeader(quote: quote, showsName: width > 300, isUpdating: market.isUpdating)
                    .contentShape(Rectangle())
                    .onTapGesture { openOnNasdaq(featured) }
                    .help("Open \(featured) on Nasdaq")
                if let chart = market.charts[featured] {
                    StockSessionGraph(
                        chart: chart,
                        currentPrice: quote.price,
                        extendedSession: DataService.tradingSession(at: Date())
                    )
                    .frame(maxHeight: .infinity)
                    chartFooter(chart, quote: quote)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxHeight: .infinity)
        } else if market.unavailable.contains(featured) {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("No Nasdaq quote for \(featured)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LoadingState(label: "Loading \(featured)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func chartFooter(_ chart: StockSessionChart, quote: StockQuote) -> some View {
        HStack(spacing: 8) {
            Text("PREV CLOSE \(chart.previousClose, format: .number.precision(.fractionLength(2)))")
            Spacer()
            if quote.isExtendedHours {
                HStack(spacing: 4) {
                    Circle().fill(.orange).frame(width: 4, height: 4)
                    Text(quote.marketStatus.uppercased())
                }
            }
            Text(chart.timeAsOf).lineLimit(1)
        }
        .font(.system(size: 7.5, weight: .bold, design: .rounded))
        .foregroundStyle(.tertiary)
        .monospacedDigit()
    }

    private func openOnNasdaq(_ symbol: String) {
        let assetClass = settings.watchlist.first { $0.symbol == symbol }?.assetClass ?? "stocks"
        let path = assetClass == "stocks" ? "stocks" : assetClass
        if let url = URL(string: "https://www.nasdaq.com/market-activity/\(path)/\(symbol.lowercased())") {
            dashboard.open(url)
        }
    }
}

private struct FeaturedQuoteHeader: View {
    let quote: StockQuote
    let showsName: Bool
    let isUpdating: Bool

    private var accent: Color { quote.change >= 0 ? .green : .red }

    private var statusColor: Color {
        if quote.isExtendedHours { return .orange }
        return quote.marketStatus.localizedCaseInsensitiveContains("open") ? .green : .secondary
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(quote.symbol)
                        .font(.system(size: 18, weight: .black, design: .rounded))
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                        .opacity(isUpdating ? 0.35 : 1)
                        .animation(.easeInOut(duration: 0.25), value: isUpdating)
                }
                Text(showsName ? "\(quote.name) · \(quote.marketStatus)" : quote.marketStatus)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(quote.price, format: .number.precision(.fractionLength(2)))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: quote.price))
                    .animation(.snappy, value: quote.price)
                Text(String(format: "%+.2f  (%+.2f%%)", quote.change, quote.changePercent))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(accent)
            }
        }
    }
}

/// Every watched symbol at a glance; click to feature it, right-click for options,
/// "+" to add one.
private struct WatchlistStrip: View {
    @ObservedObject var market: StockMarketModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var dashboard: DashboardModel
    @State private var showsAddSymbol = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(settings.watchlist) { entry in
                    chip(entry)
                }
                Button {
                    showsAddSymbol = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 26, height: 30)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("Add a symbol to the watchlist")
                .popover(isPresented: $showsAddSymbol, arrowEdge: .bottom) {
                    AddSymbolForm { showsAddSymbol = false }
                        .environmentObject(settings)
                }
            }
        }
        .frame(height: 32)
    }

    private func chip(_ entry: WatchedSymbol) -> some View {
        let quote = market.quotes[entry.symbol]
        let selected = entry.symbol == settings.featuredSymbol
        let accent: Color = (quote?.change ?? 0) >= 0 ? .green : .red
        return Button {
            withAnimation(.snappy(duration: 0.25)) { settings.featuredSymbol = entry.symbol }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(entry.symbol)
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                    if let quote {
                        Text(String(format: "%+.2f%%", quote.changePercent))
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(accent)
                    }
                }
                Text(quote.map { String(format: "%.2f", $0.price) }
                     ?? (market.unavailable.contains(entry.symbol) ? "n/a" : "…"))
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(
                selected ? accent.opacity(0.16) : Color.white.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(selected ? accent.opacity(0.55) : Color.white.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
        .help(quote.map { "\($0.name) · \($0.marketStatus)" } ?? entry.symbol)
        .contextMenu {
            Button("Feature \(entry.symbol)") { settings.featuredSymbol = entry.symbol }
            Button("Open on Nasdaq") {
                let path = entry.assetClass ?? "stocks"
                if let url = URL(string: "https://www.nasdaq.com/market-activity/\(path)/\(entry.symbol.lowercased())") {
                    dashboard.open(url)
                }
            }
            Divider()
            Button("Remove from watchlist", role: .destructive) {
                settings.removeSymbol(entry.symbol)
            }
            .disabled(settings.watchlist.count <= 1)
        }
    }
}

/// Looks the symbol up on Nasdaq before adding it, so typos don't become dead chips.
struct AddSymbolForm: View {
    @EnvironmentObject private var settings: AppSettings
    var onDone: () -> Void = {}
    @State private var text = ""
    @State private var isChecking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add to watchlist").font(.headline)
            HStack {
                TextField("Symbol, e.g. MSFT, QQQ", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .frame(width: 180)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isChecking || WatchedSymbol.normalized(text) == nil)
            }
            if isChecking {
                ProgressView().controlSize(.small)
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text("Stocks, ETFs and indexes listed on Nasdaq's quote pages.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private func add() {
        guard let symbol = WatchedSymbol.normalized(text), !isChecking else { return }
        if settings.watchlist.contains(where: { $0.symbol == symbol }) {
            settings.featuredSymbol = symbol
            onDone()
            return
        }
        isChecking = true
        error = nil
        Task {
            let result = await DataService.fetchQuote(symbol: symbol, assetClass: nil)
            isChecking = false
            guard let result else {
                error = "No Nasdaq quote found for \(symbol)."
                return
            }
            settings.addSymbol(symbol, assetClass: result.assetClass)
            settings.featuredSymbol = symbol
            text = ""
            onDone()
        }
    }
}

/// The featured symbol's session so far, green above the previous close and red below,
/// with a crosshair that reads out the price and time under the pointer.
struct StockSessionGraph: View {
    let chart: StockSessionChart
    let currentPrice: Double
    let extendedSession: TradingSession
    @State private var hoverX: CGFloat?

    var body: some View {
        Canvas { context, size in
            guard let layout = Layout(points: visiblePoints, chart: chart, currentPrice: currentPrice, size: size)
            else { return }
            let baselineY = layout.y(chart.previousClose)

            // Soft fill between the line and the previous close, split by color.
            var area = Path()
            area.move(to: CGPoint(x: layout.x(layout.points[0]), y: baselineY))
            for point in layout.points {
                area.addLine(to: CGPoint(x: layout.x(point), y: layout.y(point.price)))
            }
            area.addLine(to: CGPoint(x: layout.x(layout.points[layout.points.count - 1]), y: baselineY))
            area.closeSubpath()
            for (color, rect) in [
                (Color.green, CGRect(x: 0, y: 0, width: size.width, height: baselineY)),
                (Color.red, CGRect(x: 0, y: baselineY, width: size.width, height: size.height - baselineY))
            ] {
                context.drawLayer { layer in
                    layer.clip(to: Path(rect))
                    layer.fill(area, with: .color(color.opacity(0.13)))
                }
            }

            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: baselineY))
            baseline.addLine(to: CGPoint(x: size.width, y: baselineY))
            context.stroke(baseline, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

            if let marketOpen = layout.points.first(where: { $0.session == .regular }),
               marketOpen.id != layout.points.first?.id {
                let openX = layout.x(marketOpen)
                var divider = Path()
                divider.move(to: CGPoint(x: openX, y: 0))
                divider.addLine(to: CGPoint(x: openX, y: size.height))
                context.stroke(divider, with: .color(.secondary.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }

            var line = Path()
            for (index, point) in layout.points.enumerated() {
                let position = CGPoint(x: layout.x(point), y: layout.y(point.price))
                if index == 0 { line.move(to: position) } else { line.addLine(to: position) }
            }
            let style = StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
            for (color, rect) in [
                (Color.green, CGRect(x: 0, y: 0, width: size.width, height: baselineY)),
                (Color.red, CGRect(x: 0, y: baselineY, width: size.width, height: size.height - baselineY))
            ] {
                context.drawLayer { layer in
                    layer.clip(to: Path(rect))
                    layer.stroke(line, with: .color(color), style: style)
                }
            }

            if let last = layout.points.last {
                let end = CGPoint(x: layout.x(last), y: layout.y(last.price))
                context.fill(
                    Path(ellipseIn: CGRect(x: end.x - 2.5, y: end.y - 2.5, width: 5, height: 5)),
                    with: .color(last.price >= chart.previousClose ? .green : .red)
                )
            }

            if let hoverX, let point = layout.nearest(toX: hoverX) {
                let position = CGPoint(x: layout.x(point), y: layout.y(point.price))
                var crosshair = Path()
                crosshair.move(to: CGPoint(x: position.x, y: 0))
                crosshair.addLine(to: CGPoint(x: position.x, y: size.height))
                context.stroke(crosshair, with: .color(.white.opacity(0.35)), lineWidth: 1)
                context.fill(
                    Path(ellipseIn: CGRect(x: position.x - 3, y: position.y - 3, width: 6, height: 6)),
                    with: .color(.white)
                )
                let change = (point.price - chart.previousClose) / chart.previousClose * 100
                let label = Text("\(point.price, format: .number.precision(.fractionLength(2)))  \(String(format: "%+.2f%%", change))  \(point.timestamp.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                let resolved = context.resolve(label)
                let textSize = resolved.measure(in: size)
                let x = min(max(position.x - textSize.width / 2, 2), size.width - textSize.width - 2)
                let box = CGRect(x: x - 4, y: 1, width: textSize.width + 8, height: textSize.height + 4)
                context.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(.black.opacity(0.75)))
                context.draw(resolved, at: CGPoint(x: x, y: 3), anchor: .topLeading)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hoverX = location.x
            case .ended: hoverX = nil
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Intraday chart")
        .accessibilityValue("Current price \(currentPrice), previous close \(chart.previousClose)")
    }

    private var visiblePoints: [StockChartPoint] {
        switch extendedSession {
        case .premarket: chart.points.filter { $0.session == .premarket }
        case .afterHours: chart.points
        case .regular: chart.points.filter { $0.session != .afterHours }
        }
    }

    private struct Layout {
        let points: [StockChartPoint]
        let size: CGSize
        let firstTime: TimeInterval
        let timeRange: TimeInterval
        let minimum: Double
        let maximum: Double

        init?(points: [StockChartPoint], chart: StockSessionChart, currentPrice: Double, size: CGSize) {
            guard points.count > 1,
                  let first = points.first?.timestamp.timeIntervalSince1970,
                  let last = points.last?.timestamp.timeIntervalSince1970
            else { return nil }
            let prices = points.map(\.price) + [chart.previousClose, currentPrice]
            guard let low = prices.min(), let high = prices.max() else { return nil }
            let range = max(high - low, 0.01)
            self.points = points
            self.size = size
            firstTime = first
            timeRange = max(last - first, 1)
            minimum = low - range * 0.08
            maximum = high + range * 0.08
        }

        func x(_ point: StockChartPoint) -> CGFloat {
            size.width * (point.timestamp.timeIntervalSince1970 - firstTime) / timeRange
        }

        func y(_ price: Double) -> CGFloat {
            size.height * (1 - (price - minimum) / (maximum - minimum))
        }

        func nearest(toX target: CGFloat) -> StockChartPoint? {
            points.min { abs(x($0) - target) < abs(x($1) - target) }
        }
    }
}
