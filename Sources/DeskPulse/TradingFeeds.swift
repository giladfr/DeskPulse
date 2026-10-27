import Foundation

/// Sources and lookups for the trading widgets: the market news wire, finance TV,
/// the semiconductor heatmap and the earnings and macro calendar.
enum TradingFeeds {
    // MARK: News wire

    struct WireSource: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let url: URL
        /// Tech or semiconductor desks, kept by the "Tech only" filter whatever the headline says.
        let isTech: Bool
    }

    static let wireSources: [WireSource] = [
        .init(id: "bloomberg-tech", name: "Bloomberg", url: URL(string: "https://feeds.bloomberg.com/technology/news.rss")!, isTech: true),
        .init(id: "bloomberg-markets", name: "Bloomberg", url: URL(string: "https://feeds.bloomberg.com/markets/news.rss")!, isTech: false),
        .init(id: "cnbc-tech", name: "CNBC", url: URL(string: "https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=19854910")!, isTech: true),
        .init(id: "cnbc-markets", name: "CNBC", url: URL(string: "https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=20910258")!, isTech: false),
        .init(id: "wsj-tech", name: "WSJ", url: URL(string: "https://feeds.content.dowjones.io/public/rss/RSSWSJD")!, isTech: true),
        .init(id: "wsj-markets", name: "WSJ", url: URL(string: "https://feeds.content.dowjones.io/public/rss/RSSMarketsMain")!, isTech: false),
        .init(id: "marketwatch", name: "MarketWatch", url: URL(string: "https://feeds.content.dowjones.io/public/rss/mw_marketpulse")!, isTech: false),
        .init(id: "ft-tech", name: "FT", url: URL(string: "https://www.ft.com/technology?format=rss")!, isTech: true),
        .init(id: "seeking-alpha", name: "Seeking Alpha", url: URL(string: "https://seekingalpha.com/market_currents.xml")!, isTech: false),
        .init(id: "eetimes", name: "EE Times", url: URL(string: "https://www.eetimes.com/feed/")!, isTech: true)
    ]

    /// Yahoo Finance headlines that mention any of the symbols (US listings only).
    static func yahooHeadlinesSource(for symbols: [String]) -> WireSource? {
        let tickers = symbols.filter(MarketData.isNasdaqSymbol).prefix(12)
        guard !tickers.isEmpty else { return nil }
        var components = URLComponents(string: "https://feeds.finance.yahoo.com/rss/2.0/headline")
        components?.queryItems = [
            URLQueryItem(name: "s", value: tickers.joined(separator: ",")),
            URLQueryItem(name: "region", value: "US"),
            URLQueryItem(name: "lang", value: "en-US")
        ]
        return components?.url.map { WireSource(id: "yahoo-watchlist", name: "Yahoo", url: $0, isTech: false) }
    }

    struct WireItem: Identifiable, Equatable, Sendable {
        let title: String
        let link: URL?
        let date: Date?
        let source: String
        /// Symbols the headline is about, watched ones first.
        let tickers: [String]
        let isTech: Bool

        var id: String { link?.absoluteString ?? "\(source)|\(title)" }
    }

    /// Company names as headlines spell them, for the chip and big-tech names.
    static let companyAliases: [String: [String]] = [
        "NVDA": ["nvidia"], "AMD": ["amd", "advanced micro"], "AVGO": ["broadcom"],
        "TSM": ["tsmc", "taiwan semiconductor"], "ASML": ["asml"], "QCOM": ["qualcomm"],
        "ARM": ["arm holdings"], "AMAT": ["applied materials"], "MU": ["micron"],
        "LRCX": ["lam research"], "KLAC": ["kla corp"], "INTC": ["intel"],
        "TXN": ["texas instruments"], "ADI": ["analog devices"], "MRVL": ["marvell"],
        "SMCI": ["super micro", "supermicro"], "NXPI": ["nxp"], "ON": ["onsemi"],
        "MCHP": ["microchip technology"], "MPWR": ["monolithic power"],
        "AAPL": ["apple"], "MSFT": ["microsoft"], "GOOGL": ["alphabet", "google"],
        "AMZN": ["amazon"], "META": ["meta", "facebook"], "TSLA": ["tesla"],
        "ORCL": ["oracle"], "PLTR": ["palantir"], "DELL": ["dell"], "SNPS": ["synopsys"],
        "CDNS": ["cadence design"], "CRM": ["salesforce"], "NFLX": ["netflix"],
        "IBM": ["ibm"], "CSCO": ["cisco"], "SSNLF": ["samsung"], "SKHY": ["sk hynix"]
    ]

    /// Word beginnings that make a headline from a general markets feed count as tech
    /// ("chip" also matches "chipmaker"; "ai" must be a whole word).
    private static let techPattern = try? NSRegularExpression(
        pattern: #"\b(chip|semiconductor|semis\b|foundr|wafer|fabs?\b|gpu|cpu|hbm|memory|data ?cent|ai\b|a\.i\.|artificial intelligence|silicon|nasdaq|tech|cloud|hyperscal|export control|openai|anthropic|processor|accelerator|smartphone|server)"#,
        options: [.caseInsensitive]
    )

    /// The symbols a headline mentions: "$NVDA" or "NVDA" as a word (for tickers of three
    /// or more letters, so "ON" or "MU" in a sentence don't count), or a company name.
    static func tickers(in title: String, watched: [String]) -> [String] {
        let lower = " " + title.lowercased() + " "
        let words = Set(title.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "$" && $0 != "." }).map(String.init))
        var found: [String] = []
        let candidates = watched + companyAliases.keys.sorted()
        for symbol in candidates where !found.contains(symbol) {
            let plain = symbol.split(separator: ".").first.map(String.init) ?? symbol
            let asWord = plain.count >= 3 && words.contains(plain)
            let asCashtag = words.contains("$" + plain)
            let byName = (companyAliases[symbol] ?? []).contains { alias in
                lower.range(of: "[^a-z]" + NSRegularExpression.escapedPattern(for: alias) + "[^a-z]", options: .regularExpression) != nil
            }
            if asWord || asCashtag || byName { found.append(symbol) }
        }
        return found
    }

    static func isTechHeadline(_ title: String) -> Bool {
        techPattern?.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
    }

    /// Merges feeds newest first, without repeats (the same story often appears in
    /// several feeds, sometimes with a different link), dropping stories older than
    /// two days and keeping the newest 150.
    static func mergeWire(
        _ batches: [(WireSource, [FeedItem])],
        watched: [String],
        now: Date = Date()
    ) -> [WireItem] {
        var seenLinks = Set<String>()
        var seenTitles = Set<String>()
        var items: [WireItem] = []
        let cutoff = now.addingTimeInterval(-2 * 24 * 3600)
        for (source, feed) in batches {
            for entry in feed {
                if let date = entry.date, date < cutoff || date > now.addingTimeInterval(3600) { continue }
                let titleKey = entry.title.lowercased().filter { $0.isLetter || $0.isNumber }
                let linkKey = entry.link.map { $0.absoluteString.components(separatedBy: "?").first ?? $0.absoluteString }
                guard seenTitles.insert(titleKey).inserted else { continue }
                if let linkKey, !seenLinks.insert(linkKey).inserted { continue }
                let tickers = tickers(in: entry.title, watched: watched)
                // Yahoo's per-symbol feed mixes in general stories; keep the relevant ones.
                if source.id == "yahoo-watchlist", tickers.isEmpty, !isTechHeadline(entry.title) { continue }
                items.append(WireItem(
                    title: entry.title,
                    link: entry.link,
                    date: entry.date,
                    source: source.name,
                    tickers: tickers,
                    isTech: source.isTech || !tickers.isEmpty || isTechHeadline(entry.title)
                ))
            }
        }
        return Array(items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(150))
    }

    // MARK: Finance TV

    struct TVChannel: Identifiable, Hashable, Sendable {
        enum Source: Hashable, Sendable {
            /// The YouTube channel whose current live stream is shown.
            case youTube(channelID: String)
            /// A broadcaster's own HLS stream.
            case hls(URL)
        }

        let id: String
        let name: String
        let source: Source
    }

    static let tvChannels: [TVChannel] = [
        .init(id: "bloomberg", name: "Bloomberg", source: .youTube(channelID: "UCIALMKvObZNtJ6AmdCLP7Lg")),
        .init(id: "yahoo", name: "Yahoo Finance", source: .youTube(channelID: "UCEAZeUIeJs0IjQiqTCdVSIg")),
        // NBCUniversal's free CNBC channel (as carried by Samsung TV Plus UK). CNBC
        // Europe shows the US programmes during US market hours.
        .init(id: "cnbc", name: "CNBC", source: .hls(URL(string: "https://amg01079-nbcuuk-amg01079c2-samsung-gb-1258.playouts.now.amagi.tv/playlist.m3u8")!))
    ]

    /// The video ID of a channel's current live stream, or nil when it isn't live.
    static func liveVideoID(channelID: String) async -> String? {
        guard let url = URL(string: "https://www.youtube.com/channel/\(channelID)/live") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        guard
            let (data, _) = try? await URLSession.shared.data(for: request),
            let html = String(data: data, encoding: .utf8)
        else { return nil }
        return parseLiveVideoID(html: html)
    }

    /// A live channel's /live page is canonically the stream's watch page; an offline
    /// one is the channel page.
    static func parseLiveVideoID(html: String) -> String? {
        guard
            let marker = html.range(of: #"<link rel="canonical" href="https://www.youtube.com/watch?v="#),
            let end = html[marker.upperBound...].firstIndex(of: "\"")
        else { return nil }
        let id = String(html[marker.upperBound..<end])
        return id.count == 11 ? id : nil
    }

    // MARK: Heatmap

    struct HeatmapCategory: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        /// Roughly by market value, so tiles keep their places from day to day.
        let symbols: [String]
        /// Shown as a percentage beside the category's name.
        let benchmarks: [String]
    }

    /// The watchlist is a category too, filled from Settings.
    static let watchlistCategoryID = "watchlist"
    /// Every sector's leaders at once, in blocks.
    static let overviewCategoryID = "overview"

    typealias OverviewSection = (category: HeatmapCategory, symbols: [String])

    /// The sectors in the overview, in order.
    static let overviewSectorIDs = ["semis", "hyperscalers", "software", "cyber", "ai-infra", "israel"]

    /// The overview's blocks with the default counts: semis 9, the others 6.
    static func overviewSections() -> [OverviewSection] {
        overviewSections(counts: Dictionary(uniqueKeysWithValues: overviewSectorIDs.map { ($0, $0 == "semis" ? 9 : 6) }))
    }

    /// Each sector's first names, in order, skipping any already shown in an earlier
    /// block (Oracle, Check Point).
    static func overviewSections(counts: [String: Int]) -> [OverviewSection] {
        var shown = Set<String>()
        return overviewSectorIDs.compactMap { id in
            guard let category = heatmapCategories.first(where: { $0.id == id }) else { return nil }
            let symbols = category.symbols.filter { !shown.contains($0) }.prefix(counts[id] ?? 0)
            shown.formUnion(symbols)
            return (category, Array(symbols))
        }
    }

    struct OverviewPlan {
        let across: Int
        /// Blocks per column, top to bottom.
        let columns: [[OverviewSection]]
        let tileHeight: Double
    }

    /// Lays the overview out to use the card: tiles at least 92 points wide (three or
    /// more across a block), blocks in two columns balanced by height, then extra rows
    /// for sectors in a column with room left, as long as its tiles stay at least
    /// `minimumTile` tall, or as tall as the other column already makes them, so a
    /// bigger card shows more names rather than bigger tiles, with no empty rows.
    static func overviewPlan(
        width: Double,
        height: Double,
        minimumTile: Double = 72,
        maximumTile: Double = 96
    ) -> OverviewPlan {
        let headerHeight = 18.0, blockGap = 8.0, tileGap = 4.0
        let twoColumns = width >= 520
        let columnWidth = twoColumns ? (width - 10) / 2 : width
        let across = max(3, Int(columnWidth / 92))
        var rows = Dictionary(uniqueKeysWithValues: overviewSectorIDs.map { ($0, $0 == "semis" ? 3 : 2) })

        func sections() -> [OverviewSection] {
            overviewSections(counts: rows.mapValues { $0 * across })
        }
        func usedRows(_ section: OverviewSection) -> Int {
            Int((Double(section.symbols.count) / Double(across)).rounded(.up))
        }
        // Columns are chosen once, from the starting sizes, so blocks don't jump about.
        let start = sections()
        let assignment = twoColumns
            ? balancedColumns(rows: start.map(usedRows))
            : [Array(start.indices)]
        func tileHeight(column: [Int], in current: [OverviewSection]) -> Double {
            let rowCount = column.map { usedRows(current[$0]) }.reduce(0, +)
            guard rowCount > 0 else { return maximumTile }
            let fixed = Double(column.count) * (headerHeight + blockGap) - blockGap
                + Double(rowCount - column.count) * tileGap
            return (height - fixed) / Double(rowCount)
        }

        var grew = true
        while grew {
            grew = false
            for column in assignment {
                let current = sections()
                // The block with the most names still unseen gets the next row.
                let candidates = column.filter { index in
                    let section = current[index]
                    let shownElsewhere = Set(current.enumerated().filter { $0.offset != index }.flatMap(\.element.symbols))
                    let available = section.category.symbols.filter { !shownElsewhere.contains($0) }.count
                    return available > section.symbols.count
                }
                guard let index = candidates.max(by: {
                    current[$0].category.symbols.count - current[$0].symbols.count
                        < current[$1].category.symbols.count - current[$1].symbols.count
                }) else { continue }
                let id = current[index].category.id
                // All tiles share one height: the shortest column's. Growing to that
                // height costs nothing.
                let shared = assignment.map { tileHeight(column: $0, in: current) }.min() ?? minimumTile
                rows[id, default: 0] += 1
                if tileHeight(column: column, in: sections()) >= min(minimumTile, shared) - 0.01 {
                    grew = true
                } else {
                    rows[id, default: 1] -= 1
                }
            }
        }

        let final = sections()
        let height = assignment.map { tileHeight(column: $0, in: final) }.min() ?? minimumTile
        return OverviewPlan(
            across: across,
            columns: assignment.map { $0.map { final[$0] }.filter { !$0.symbols.isEmpty } },
            tileHeight: min(maximumTile, max(48, height))
        )
    }

    /// Splits blocks of the given row counts into two columns of similar height,
    /// keeping their order within each column; returns the block indices per column.
    static func balancedColumns(rows: [Int]) -> [[Int]] {
        var columns: [[Int]] = [[], []]
        var heights = [0, 0]
        for (index, count) in rows.enumerated() {
            let target = heights[0] <= heights[1] ? 0 : 1
            columns[target].append(index)
            heights[target] += count
        }
        return columns
    }

    static let heatmapCategories: [HeatmapCategory] = [
        .init(id: "semis", name: "Semis", symbols: semiconductorSymbols, benchmarks: ["SOXX", "SMH"]),
        .init(id: "hyperscalers", name: "Hyperscalers", symbols: [
            "MSFT", "AMZN", "GOOGL", "META", "ORCL", "CRWV", "NBIS", "IBM", "BABA", "EQIX", "DLR"
        ], benchmarks: ["QQQ"]),
        .init(id: "software", name: "Software", symbols: [
            "ORCL", "SAP", "CRM", "PLTR", "NOW", "INTU", "ADBE", "APP", "SHOP", "SNPS",
            "CDNS", "ADSK", "WDAY", "SNOW", "DDOG", "TEAM", "MDB", "HUBS"
        ], benchmarks: ["IGV"]),
        .init(id: "cyber", name: "Cybersecurity", symbols: [
            "PANW", "CRWD", "FTNT", "NET", "ZS", "CHKP", "AKAM", "OKTA", "QLYS", "TENB", "S", "RPD"
        ], benchmarks: ["CIBR"]),
        .init(id: "ai-infra", name: "AI infrastructure", symbols: [
            "CSCO", "ANET", "DELL", "GLW", "VRT", "CLS", "HPE", "COHR", "CIEN", "LITE",
            "SMCI", "CRDO", "ALAB", "NTAP"
        ], benchmarks: []),
        .init(id: "mag7", name: "Mag 7", symbols: [
            "NVDA", "MSFT", "AAPL", "GOOGL", "AMZN", "META", "TSLA"
        ], benchmarks: ["MAGS", "QQQ"]),
        .init(id: "israel", name: "Israeli tech", symbols: [
            "CHKP", "TSEM", "NVMI", "ESLT", "MNDY", "NICE", "CAMT", "WIX", "CLBT", "GLBE",
            "FVRR", "RDWR", "SEDG"
        ], benchmarks: ["^TA125.TA"])
    ]

    static let semiconductorSymbols = [
        "NVDA", "AVGO", "TSM", "AMD", "ASML", "QCOM", "INTC", "AMAT", "MU", "ARM",
        "LRCX", "KLAC", "TXN", "ADI", "MRVL", "SMCI", "NXPI", "MPWR", "ON", "MCHP"
    ]

    // MARK: Earnings

    enum ReportTime: String, Sendable {
        case beforeOpen, afterClose, unknown
    }

    struct Earnings: Identifiable, Equatable, Sendable {
        var id: String { "\(symbol)|\(day)" }
        let symbol: String
        let name: String
        /// "yyyy-MM-dd", New York.
        let day: String
        let time: ReportTime
        let epsEstimate: String?
        let marketCap: Double?
    }

    /// Big tech reports move the semis too, so they are shown with the watchlist.
    static let bigTechSymbols: Set<String> = [
        "AAPL", "MSFT", "GOOGL", "AMZN", "META", "TSLA", "NFLX", "ORCL", "CRM", "ADBE",
        "PLTR", "IBM", "CSCO", "DELL", "HPQ", "SNPS", "CDNS", "ANET", "NOW", "SHOP"
    ]

    private struct NasdaqEarnings: Decodable {
        struct DataBlock: Decodable { let rows: [Row]? }
        struct Row: Decodable {
            let symbol: String?
            let name: String?
            let time: String?
            let epsForecast: String?
            let marketCap: String?
        }
        let data: DataBlock?
    }

    static func fetchEarnings(day: String) async -> [Earnings]? {
        guard let url = URL(string: "https://api.nasdaq.com/api/calendar/earnings?date=\(day)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return parseEarnings(data, day: day)
    }

    static func parseEarnings(_ data: Data, day: String) -> [Earnings] {
        guard let decoded = try? JSONDecoder().decode(NasdaqEarnings.self, from: data) else { return [] }
        return (decoded.data?.rows ?? []).compactMap { row in
            guard let symbol = row.symbol?.trimmingCharacters(in: .whitespaces), !symbol.isEmpty else { return nil }
            let time: ReportTime = switch row.time {
            case "time-pre-market": .beforeOpen
            case "time-after-hours": .afterClose
            default: .unknown
            }
            let estimate = row.epsForecast?.trimmingCharacters(in: .whitespaces)
            return Earnings(
                symbol: symbol,
                name: DataService.cleanCompanyName(row.name ?? symbol),
                day: day,
                time: time,
                epsEstimate: (estimate?.isEmpty ?? true) ? nil : estimate,
                marketCap: row.marketCap.flatMap { Double($0.filter { $0.isNumber || $0 == "." }) }
            )
        }
    }

    /// The reports worth showing: watched symbols, semis and big tech; GOOG folds
    /// into GOOGL.
    static func relevantEarnings(_ all: [Earnings], watched: Set<String>) -> [Earnings] {
        let wanted = watched.union(semiconductorSymbols).union(bigTechSymbols)
        var seen = Set<String>()
        return all
            .filter { $0.symbol != "GOOG" && wanted.contains($0.symbol) }
            .filter { seen.insert($0.id).inserted }
            .sorted {
                if $0.day != $1.day { return $0.day < $1.day }
                if $0.time != $1.time { return $0.time == .beforeOpen }
                return ($0.marketCap ?? 0) > ($1.marketCap ?? 0)
            }
    }

    // MARK: Macro calendar

    enum Impact: String, Sendable { case high = "High", medium = "Medium", low = "Low" }

    struct MacroEvent: Identifiable, Equatable, Sendable {
        var id: String { "\(title)|\(date.timeIntervalSince1970)" }
        let title: String
        let date: Date
        let impact: Impact
        let forecast: String?
        let previous: String?
        let actual: String?
    }

    private struct FairEconomyEvent: Decodable {
        let title: String
        let country: String
        let date: String
        let impact: String
        let forecast: String?
        let previous: String?
        let actual: String?
    }

    /// This week's (and, once published, next week's) US events of medium or high impact, from the free
    /// Forex Factory export. It updates actuals a few minutes after a release.
    static func fetchMacro() async -> [MacroEvent]? {
        var events: [MacroEvent] = []
        var anySucceeded = false
        for week in ["thisweek", "nextweek"] {
            guard
                let url = URL(string: "https://nfs.faireconomy.media/ff_calendar_\(week).json"),
                let (data, response) = try? await URLSession.shared.data(from: url),
                (response as? HTTPURLResponse)?.statusCode == 200
            else { continue }
            anySucceeded = true
            events += parseMacro(data)
        }
        return anySucceeded ? events.sorted { $0.date < $1.date } : nil
    }

    static func parseMacro(_ data: Data) -> [MacroEvent] {
        guard let decoded = try? JSONDecoder().decode([FairEconomyEvent].self, from: data) else { return [] }
        let formatter = ISO8601DateFormatter()
        func text(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            return value
        }
        return decoded.compactMap { event in
            guard
                event.country == "USD",
                let impact = Impact(rawValue: event.impact),
                impact != .low,
                let date = formatter.date(from: event.date)
            else { return nil }
            return MacroEvent(
                title: event.title,
                date: date,
                impact: impact,
                forecast: text(event.forecast),
                previous: text(event.previous),
                actual: text(event.actual)
            )
        }
    }
}
