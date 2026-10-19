import Foundation

/// The latest price of one symbol, for tiles, the ticker and price alerts.
struct MarketQuote: Equatable, Sendable {
    let symbol: String
    /// The latest trade, including pre-market and after-hours trading.
    let price: Double
    /// The regular session's price: live while it trades, its close afterwards.
    let sessionPrice: Double
    /// The close before the session `sessionPrice` belongs to.
    let previousClose: Double
    /// Regular-session prices through that session, oldest first.
    let sparkline: [Double]
    let sessionStart: Date?
    let sessionEnd: Date?

    var dayChange: Double { sessionPrice - previousClose }
    var dayChangePercent: Double { previousClose == 0 ? 0 : dayChange / previousClose * 100 }

    /// The pre-market or after-hours move from the regular close, if there is one.
    var extendedChange: Double? {
        let change = price - sessionPrice
        return abs(change) >= max(0.005, abs(sessionPrice) * 0.0002) ? change : nil
    }

    var extendedChangePercent: Double? {
        extendedChange.map { sessionPrice == 0 ? 0 : $0 / sessionPrice * 100 }
    }

    func isTrading(at date: Date) -> Bool {
        guard let sessionStart, let sessionEnd else { return false }
        return date >= sessionStart && date < sessionEnd
    }

    /// Yahoo quotes Tel Aviv shares in agorot; `0.01` turns them into shekels.
    func scaled(by factor: Double) -> MarketQuote {
        guard factor != 1 else { return self }
        return MarketQuote(
            symbol: symbol,
            price: price * factor,
            sessionPrice: sessionPrice * factor,
            previousClose: previousClose * factor,
            sparkline: sparkline.map { $0 * factor },
            sessionStart: sessionStart,
            sessionEnd: sessionEnd
        )
    }
}

/// What changes slowly about a symbol: its name, currency, ranges and trading hours.
struct SymbolDetails: Equatable, Sendable {
    let symbol: String
    let name: String
    /// The currency prices are shown in, e.g. "USD" or "ILS".
    let currency: String
    /// Multiplies Yahoo's prices into `currency` (0.01 for agorot).
    let priceScale: Double
    let exchange: String
    let instrumentType: String
    let dayHigh: Double?
    let dayLow: Double?
    let yearHigh: Double?
    let yearLow: Double?
    let volume: Double?
    let regularStart: Date?
    let regularEnd: Date?
    let fetchedAt: Date

    var currencySymbol: String {
        switch currency {
        case "USD": "$"
        case "ILS": "₪"
        case "EUR": "€"
        case "GBP": "£"
        case "JPY": "¥"
        default: ""
        }
    }

    /// Indexes and exchange rates have no currency to show.
    var showsCurrency: Bool {
        !["INDEX", "CURRENCY"].contains(instrumentType)
    }
}

enum ChartRange: String, CaseIterable, Identifiable, Codable, Sendable {
    case day = "1D"
    case fiveDays = "5D"
    case month = "1M"
    case sixMonths = "6M"
    case year = "1Y"

    var id: String { rawValue }

    var query: (range: String, interval: String) {
        switch self {
        case .day: ("1d", "2m")
        case .fiveDays: ("5d", "15m")
        case .month: ("1mo", "60m")
        case .sixMonths: ("6mo", "1d")
        case .year: ("1y", "1d")
        }
    }

    /// Intraday charts move; longer ones only need an occasional refresh.
    var refreshSeconds: Double { self == .day ? 30 : 300 }
}

/// Prices over a range, with the price they are compared against: the previous close
/// for one day, otherwise the close before the range began.
struct PriceChart: Equatable, Sendable {
    let symbol: String
    let range: ChartRange
    let points: [StockChartPoint]
    let baseline: Double

    func scaled(by factor: Double) -> PriceChart {
        guard factor != 1 else { return self }
        return PriceChart(
            symbol: symbol,
            range: range,
            points: points.map {
                StockChartPoint(timestamp: $0.timestamp, price: $0.price * factor, session: $0.session)
            },
            baseline: baseline * factor
        )
    }
}

struct SymbolSearchResult: Identifiable, Equatable, Sendable {
    var id: String { symbol }
    let symbol: String
    let name: String
    let exchange: String
    let type: String
}

/// Yahoo Finance's public chart endpoints. Like the Nasdaq API they are unofficial;
/// Nasdaq stays as the fallback for US listings.
enum YahooFinance {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        return URLSession(configuration: configuration)
    }()

    private static func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Browser user agents are sent to a cookie check and rate-limited; an
        // app that says what it is gets the API.
        request.setValue("DeskPulse/1.0", forHTTPHeaderField: "User-Agent")
        guard
            let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    private static func url(_ path: String, _ items: [URLQueryItem]) -> URL? {
        var components = URLComponents(string: "https://query1.finance.yahoo.com\(path)")
        components?.queryItems = items
        return components?.url
    }

    private static func pathSymbol(_ symbol: String) -> String {
        symbol.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-"))) ?? symbol
    }

    // MARK: Quotes

    /// Today's regular-session prices for many symbols in one request. Symbols Yahoo
    /// doesn't know are missing from the result. Prices are as Yahoo quotes them.
    static func fetchSpark(_ symbols: [String]) async -> [String: MarketQuote]? {
        guard !symbols.isEmpty else { return [:] }
        var merged: [String: MarketQuote] = [:]
        var anySucceeded = false
        for chunk in stride(from: 0, to: symbols.count, by: 20).map({ Array(symbols[$0..<min($0 + 20, symbols.count)]) }) {
            guard
                let url = url("/v8/finance/spark", [
                    URLQueryItem(name: "symbols", value: chunk.joined(separator: ",")),
                    URLQueryItem(name: "range", value: "1d"),
                    URLQueryItem(name: "interval", value: "5m")
                ]),
                let data = await get(url)
            else { continue }
            anySucceeded = true
            merged.merge(parseSpark(data), uniquingKeysWith: { _, new in new })
        }
        return anySucceeded ? merged : nil
    }

    private struct SparkEntry: Decodable {
        let symbol: String?
        let timestamp: [Double]?
        let close: [Double?]?
        let previousClose: Double?
        let chartPreviousClose: Double?
        let fulldayPrice: Double?
        let start: Double?
        let end: Double?
    }

    static func parseSpark(_ data: Data, now: Date = Date()) -> [String: MarketQuote] {
        guard let entries = try? JSONDecoder().decode([String: SparkEntry].self, from: data) else { return [:] }
        var quotes: [String: MarketQuote] = [:]
        for (key, entry) in entries {
            let closes = (entry.close ?? []).compactMap { $0 }
            guard
                let lastClose = closes.last,
                let previousClose = entry.chartPreviousClose ?? entry.previousClose
            else { continue }
            let start = entry.start.map { Date(timeIntervalSince1970: $0) }
            let end = entry.end.map { Date(timeIntervalSince1970: $0) }
            let price = entry.fulldayPrice ?? lastClose
            let trading = start.map { now >= $0 } == true && end.map { now < $0 } == true
            let symbol = entry.symbol ?? key
            quotes[symbol] = MarketQuote(
                symbol: symbol,
                price: price,
                // During the session the latest trade is the session price (the 5-minute
                // bars lag a little); afterwards the session's close is.
                sessionPrice: trading ? price : lastClose,
                previousClose: previousClose,
                sparkline: closes,
                sessionStart: start,
                sessionEnd: end
            )
        }
        return quotes
    }

    // MARK: Charts and details

    private struct ChartResponse: Decodable {
        struct Chart: Decodable { let result: [Result]? }
        struct Result: Decodable {
            let meta: Meta
            let timestamp: [Double]?
            let indicators: Indicators?
        }
        struct Indicators: Decodable { let quote: [Series]? }
        struct Series: Decodable { let close: [Double?]? }
        struct Period: Decodable { let start: Double; let end: Double }
        struct TradingPeriods: Decodable { let pre: Period?; let regular: Period?; let post: Period? }
        struct Meta: Decodable {
            let symbol: String
            let currency: String?
            let exchangeName: String?
            let fullExchangeName: String?
            let instrumentType: String?
            let longName: String?
            let shortName: String?
            let regularMarketPrice: Double?
            let regularMarketTime: Double?
            let previousClose: Double?
            let chartPreviousClose: Double?
            let regularMarketDayHigh: Double?
            let regularMarketDayLow: Double?
            let fiftyTwoWeekHigh: Double?
            let fiftyTwoWeekLow: Double?
            let regularMarketVolume: Double?
            let currentTradingPeriod: TradingPeriods?
        }
        let chart: Chart
    }

    /// A chart and the symbol's details, both in display currency.
    static func fetchChart(_ symbol: String, range: ChartRange) async -> (chart: PriceChart, details: SymbolDetails)? {
        guard
            let url = url("/v8/finance/chart/\(pathSymbol(symbol))", [
                URLQueryItem(name: "range", value: range.query.range),
                URLQueryItem(name: "interval", value: range.query.interval),
                URLQueryItem(name: "includePrePost", value: range == .day ? "true" : "false")
            ]),
            let data = await get(url)
        else { return nil }
        return parseChart(data, range: range)
    }

    /// Details only, from the smallest chart Yahoo serves.
    static func fetchDetails(_ symbol: String) async -> SymbolDetails? {
        guard
            let url = url("/v8/finance/chart/\(pathSymbol(symbol))", [
                URLQueryItem(name: "range", value: "1d"),
                URLQueryItem(name: "interval", value: "1d")
            ]),
            let data = await get(url),
            let meta = decodeMeta(data)
        else { return nil }
        return details(from: meta)
    }

    private static func decodeMeta(_ data: Data) -> ChartResponse.Meta? {
        (try? JSONDecoder().decode(ChartResponse.self, from: data))?.chart.result?.first?.meta
    }

    static func parseDetails(_ data: Data, now: Date = Date()) -> SymbolDetails? {
        decodeMeta(data).map { details(from: $0, now: now) }
    }

    private static func details(from meta: ChartResponse.Meta, now: Date = Date()) -> SymbolDetails {
        let rawCurrency = meta.currency ?? "USD"
        // Tel Aviv shares are quoted in agorot ("ILA"), a hundredth of a shekel.
        let scale = rawCurrency == "ILA" ? 0.01 : 1
        let name = meta.longName ?? meta.shortName ?? meta.symbol
        return SymbolDetails(
            symbol: meta.symbol,
            name: DataService.cleanCompanyName(name),
            currency: rawCurrency == "ILA" ? "ILS" : rawCurrency,
            priceScale: scale,
            exchange: meta.fullExchangeName ?? meta.exchangeName ?? "",
            instrumentType: meta.instrumentType ?? "EQUITY",
            dayHigh: meta.regularMarketDayHigh.map { $0 * scale },
            dayLow: meta.regularMarketDayLow.map { $0 * scale },
            yearHigh: meta.fiftyTwoWeekHigh.map { $0 * scale },
            yearLow: meta.fiftyTwoWeekLow.map { $0 * scale },
            volume: meta.regularMarketVolume,
            regularStart: meta.currentTradingPeriod?.regular.map { Date(timeIntervalSince1970: $0.start) },
            regularEnd: meta.currentTradingPeriod?.regular.map { Date(timeIntervalSince1970: $0.end) },
            fetchedAt: now
        )
    }

    static func parseChart(_ data: Data, range: ChartRange, now: Date = Date()) -> (chart: PriceChart, details: SymbolDetails)? {
        guard
            let result = (try? JSONDecoder().decode(ChartResponse.self, from: data))?.chart.result?.first,
            let timestamps = result.timestamp,
            let closes = result.indicators?.quote?.first?.close
        else { return nil }
        let meta = result.meta
        let details = details(from: meta, now: now)
        let regular = meta.currentTradingPeriod?.regular
        var points: [StockChartPoint] = []
        for (time, close) in zip(timestamps, closes) {
            guard let close else { continue }
            let session: TradingSession
            if range == .day, let regular {
                session = time < regular.start ? .premarket : time >= regular.end ? .afterHours : .regular
            } else {
                session = .regular
            }
            points.append(StockChartPoint(timestamp: Date(timeIntervalSince1970: time), price: close, session: session))
        }
        guard let first = points.first else { return nil }

        let baseline: Double
        if range == .day,
           let regular,
           let lastClose = meta.regularMarketPrice,
           let lastTrade = meta.regularMarketTime,
           lastTrade < regular.start {
            // Before today's session (pre-market) the "previous close" Yahoo reports is
            // two sessions old; the last session's close is the right comparison.
            baseline = lastClose
        } else {
            baseline = meta.chartPreviousClose ?? meta.previousClose ?? first.price
        }
        let chart = PriceChart(symbol: meta.symbol, range: range, points: points, baseline: baseline)
        return (chart.scaled(by: details.priceScale), details)
    }

    // MARK: Search

    static func search(_ query: String) async -> [SymbolSearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !query.isEmpty,
            let url = url("/v1/finance/search", [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "quotesCount", value: "8"),
                URLQueryItem(name: "newsCount", value: "0")
            ]),
            let data = await get(url)
        else { return [] }
        return parseSearch(data)
    }

    private struct SearchResponse: Decodable {
        struct Quote: Decodable {
            let symbol: String?
            let shortname: String?
            let longname: String?
            let exchDisp: String?
            let quoteType: String?
        }
        let quotes: [Quote]?
    }

    static let searchableTypes: Set<String> = [
        "EQUITY", "ETF", "INDEX", "CURRENCY", "CRYPTOCURRENCY", "FUTURE", "MUTUALFUND"
    ]

    static func parseSearch(_ data: Data) -> [SymbolSearchResult] {
        guard let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else { return [] }
        return (response.quotes ?? []).compactMap { quote in
            guard
                let symbol = quote.symbol,
                let type = quote.quoteType,
                searchableTypes.contains(type)
            else { return nil }
            return SymbolSearchResult(
                symbol: symbol,
                name: quote.longname ?? quote.shortname ?? symbol,
                exchange: quote.exchDisp ?? "",
                type: type
            )
        }
    }
}

/// Symbol details are shared by the stock card and the price-alert monitor and
/// refetched every ten minutes (trading hours roll over, ranges move).
actor SymbolDetailsCache {
    static let shared = SymbolDetailsCache()

    private var cached: [String: SymbolDetails] = [:]

    func store(_ details: SymbolDetails) {
        cached[details.symbol] = details
    }

    func details(for symbols: [String], maxAge: TimeInterval = 600) async -> [String: SymbolDetails] {
        let now = Date()
        let stale = symbols.filter { symbol in
            cached[symbol].map { now.timeIntervalSince($0.fetchedAt) > maxAge } ?? true
        }
        if !stale.isEmpty {
            let fetched = await withTaskGroup(of: SymbolDetails?.self) { group in
                for symbol in stale {
                    group.addTask { await YahooFinance.fetchDetails(symbol) }
                }
                var results: [SymbolDetails] = []
                for await details in group {
                    if let details { results.append(details) }
                }
                return results
            }
            for details in fetched { cached[details.symbol] = details }
        }
        return cached.filter { symbols.contains($0.key) }
    }
}

enum MarketData {
    /// Symbols Nasdaq's API can answer for: plain US tickers.
    static func isNasdaqSymbol(_ symbol: String) -> Bool {
        !symbol.contains(where: { ".^=".contains($0) })
    }

    /// Quotes in display currency for many symbols: Yahoo first, Nasdaq for US symbols
    /// Yahoo didn't answer. Tel Aviv quotes wait for their details, so agorot are never
    /// shown as shekels.
    static func fetchQuotes(
        _ entries: [WatchedSymbol]
    ) async -> (quotes: [String: MarketQuote], details: [String: SymbolDetails], nasdaqClasses: [String: String]) {
        let symbols = entries.map(\.symbol)
        async let detailsTask = SymbolDetailsCache.shared.details(for: symbols)
        let spark = await YahooFinance.fetchSpark(symbols) ?? [:]
        let details = await detailsTask

        var quotes: [String: MarketQuote] = [:]
        for (symbol, quote) in spark {
            if let scale = details[symbol]?.priceScale {
                quotes[symbol] = quote.scaled(by: scale)
            } else if !symbol.uppercased().hasSuffix(".TA") {
                quotes[symbol] = quote
            }
        }

        var nasdaqClasses: [String: String] = [:]
        let missing = entries.filter { quotes[$0.symbol] == nil && isNasdaqSymbol($0.symbol) }
        if !missing.isEmpty {
            let fallback = await withTaskGroup(of: (String, (quote: StockQuote, assetClass: String)?).self) { group in
                for entry in missing {
                    group.addTask {
                        (entry.symbol, await DataService.fetchQuote(symbol: entry.symbol, assetClass: entry.assetClass))
                    }
                }
                var results: [(String, (quote: StockQuote, assetClass: String)?)] = []
                for await result in group { results.append(result) }
                return results
            }
            for (symbol, result) in fallback {
                guard let result else { continue }
                quotes[symbol] = MarketQuote(nasdaq: result.quote)
                nasdaqClasses[symbol] = result.assetClass
            }
        }
        return (quotes, details, nasdaqClasses)
    }
}

extension MarketQuote {
    /// A Nasdaq quote has no session breakdown; its change is since the previous close.
    init(nasdaq quote: StockQuote) {
        self.init(
            symbol: quote.symbol,
            price: quote.price,
            sessionPrice: quote.price,
            previousClose: quote.price - quote.change,
            sparkline: [],
            sessionStart: nil,
            sessionEnd: nil
        )
    }
}

/// When a market opens or closes next, from Yahoo's trading period for today.
enum MarketClock {
    static func status(now: Date, start: Date?, end: Date?) -> (isOpen: Bool, text: String) {
        guard let start, let end else { return (false, "closed") }
        if now < start { return (false, "opens in \(duration(start.timeIntervalSince(now)))") }
        if now < end { return (true, "closes in \(duration(end.timeIntervalSince(now)))") }
        return (false, "closed")
    }

    /// "2h 05m", "45m", "<1m".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        return String(format: "%dh %02dm", hours, minutes % 60)
    }
}

/// Holdings valued in dollars, with shekel holdings converted at the USD/ILS rate.
struct PortfolioSummary: Equatable {
    let value: Double
    let dayChange: Double
    let totalChange: Double?
    let cost: Double?
    /// Shekels per dollar, when known, to show the totals in shekels too.
    let shekelsPerDollar: Double?

    var dayChangePercent: Double {
        let start = value - dayChange
        return start == 0 ? 0 : dayChange / start * 100
    }

    var totalChangePercent: Double? {
        guard let totalChange, let cost, cost != 0 else { return nil }
        return totalChange / cost * 100
    }

    /// Positions in currencies other than dollars and shekels are left out.
    static func make(
        positions: [(entry: WatchedSymbol, quote: MarketQuote, currency: String)],
        shekelsPerDollar: Double?
    ) -> PortfolioSummary? {
        var value = 0.0, day = 0.0, total = 0.0, cost = 0.0
        var counted = 0
        var allHaveCost = true
        for (entry, quote, currency) in positions {
            guard let shares = entry.shares, shares != 0 else { continue }
            let toDollars: Double
            switch currency {
            case "USD": toDollars = 1
            case "ILS":
                guard let rate = shekelsPerDollar, rate > 0 else { continue }
                toDollars = 1 / rate
            default: continue
            }
            counted += 1
            value += shares * quote.price * toDollars
            day += shares * quote.dayChange * toDollars
            if let averageCost = entry.averageCost {
                cost += shares * averageCost * toDollars
                total += shares * (quote.price - averageCost) * toDollars
            } else {
                allHaveCost = false
            }
        }
        guard counted > 0 else { return nil }
        return PortfolioSummary(
            value: value,
            dayChange: day,
            totalChange: allHaveCost ? total : nil,
            cost: allHaveCost ? cost : nil,
            shekelsPerDollar: shekelsPerDollar
        )
    }
}
