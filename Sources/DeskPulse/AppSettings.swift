import Foundation

struct WeatherLocation: Codable, Equatable, Hashable {
    var name: String
    var latitude: Double
    var longitude: Double
    /// IANA identifier, e.g. "America/Chicago".
    var timeZone: String

    static let austin = WeatherLocation(
        name: "Austin",
        latitude: 30.2672,
        longitude: -97.7431,
        timeZone: "America/Chicago"
    )
}

enum TemperatureUnit: String, Codable, CaseIterable, Identifiable {
    case fahrenheit, celsius

    var id: String { rawValue }
    var title: String { self == .fahrenheit ? "Fahrenheit (°F, mph)" : "Celsius (°C, km/h)" }
    var windLabel: String { self == .fahrenheit ? "mph" : "km/h" }
}

struct WatchedSymbol: Codable, Equatable, Hashable, Identifiable {
    var symbol: String
    /// Nasdaq's asset class ("stocks", "etf" or "index"), learned on first lookup.
    var assetClass: String?

    var id: String { symbol }

    /// "amd", " nasdaq:amd " → "AMD". Letters, digits, "." and "-" only.
    static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let symbol = String(trimmed.split(separator: ":").last ?? "")
            .filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        return symbol.isEmpty || symbol.count > 12 ? nil : symbol
    }

    static let defaults: [WatchedSymbol] = ["AMD", "NVDA", "AVGO", "TSM", "SOXX"]
        .map { WatchedSymbol(symbol: $0) }
}

struct WorldClock: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var timeZone: String
    var flag: String

    static let defaults: [WorldClock] = [
        WorldClock(name: "Austin", timeZone: "America/Chicago", flag: "🇺🇸"),
        WorldClock(name: "Israel", timeZone: "Asia/Jerusalem", flag: "🇮🇱"),
        WorldClock(name: "China", timeZone: "Asia/Shanghai", flag: "🇨🇳"),
        WorldClock(name: "India", timeZone: "Asia/Kolkata", flag: "🇮🇳")
    ]
}

struct NewsSource: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var url: URL
    var isEnabled = true

    /// A Google News search feed for any topic, e.g. "semiconductors" or "AMD".
    static func googleNews(topic: String) -> NewsSource? {
        let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return nil }
        var components = URLComponents(string: "https://news.google.com/rss/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: "\(topic) when:1d"),
            URLQueryItem(name: "hl", value: "en-US"),
            URLQueryItem(name: "gl", value: "US"),
            URLQueryItem(name: "ceid", value: "US:en")
        ]
        return components?.url.map { NewsSource(name: topic, url: $0) }
    }

    /// Well-known public RSS feeds offered in Settings.
    static let catalog: [(group: String, sources: [NewsSource])] = [
        ("World", [
            .init(name: "BBC World", url: URL(string: "https://feeds.bbci.co.uk/news/world/rss.xml")!),
            .init(name: "The Guardian World", url: URL(string: "https://www.theguardian.com/world/rss")!),
            .init(name: "NYT World", url: URL(string: "https://rss.nytimes.com/services/xml/rss/nyt/World.xml")!),
            .init(name: "NPR News", url: URL(string: "https://feeds.npr.org/1001/rss.xml")!),
            .init(name: "Al Jazeera", url: URL(string: "https://www.aljazeera.com/xml/rss/all.xml")!)
        ]),
        ("Israel", [
            .init(name: "Times of Israel", url: URL(string: "https://www.timesofisrael.com/feed/")!),
            .init(name: "Jerusalem Post", url: URL(string: "https://www.jpost.com/rss/rssfeedsheadlines.aspx")!),
            .init(name: "Globes (גלובס)", url: URL(string: "https://www.globes.co.il/webservice/rss/rssfeeder.asmx/FeederNode?iID=2")!),
            .init(name: "Walla (וואלה)", url: URL(string: "https://rss.walla.co.il/feed/1")!)
        ]),
        ("Markets", [
            .init(name: "CNBC Top News", url: URL(string: "https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=100003114")!),
            .init(name: "MarketWatch", url: URL(string: "https://feeds.content.dowjones.io/public/rss/mw_topstories")!)
        ]),
        ("Technology", [
            .init(name: "Hacker News", url: URL(string: "https://hnrss.org/frontpage")!),
            .init(name: "The Verge", url: URL(string: "https://www.theverge.com/rss/index.xml")!),
            .init(name: "Ars Technica", url: URL(string: "https://feeds.arstechnica.com/arstechnica/index")!),
            .init(name: "TechCrunch", url: URL(string: "https://techcrunch.com/feed/")!),
            .init(name: "BBC Technology", url: URL(string: "https://feeds.bbci.co.uk/news/technology/rss.xml")!)
        ])
    ]

    static let defaults: [NewsSource] = [
        catalog[0].sources[0],
        catalog[1].sources[0],
        catalog[3].sources[0]
    ]
}

/// "Tell me when NVDA rises above 150" or "when AMD moves 3% today".
struct PriceAlert: Codable, Equatable, Hashable, Identifiable {
    enum Condition: Codable, Hashable {
        case above(Double)
        case below(Double)
        /// Absolute change since the previous close, in percent.
        case dailyMove(Double)
    }

    var id = UUID()
    var symbol: String
    var condition: Condition
    /// For daily moves: the day ("yyyy-MM-dd", New York) it last fired, so it fires
    /// at most once per trading day.
    var lastFiredDay: String?

    func isTriggered(by quote: StockQuote, today: String) -> Bool {
        guard quote.symbol == symbol else { return false }
        switch condition {
        case .above(let price): return quote.price >= price
        case .below(let price): return quote.price <= price
        case .dailyMove(let percent): return abs(quote.changePercent) >= percent && lastFiredDay != today
        }
    }

    /// Above/below alerts are done once they fire; daily moves repeat the next day.
    var isOneShot: Bool {
        if case .dailyMove = condition { return false }
        return true
    }

    var summary: String {
        switch condition {
        case .above(let price): "\(symbol) rises above \(String(format: "%.2f", price))"
        case .below(let price): "\(symbol) falls below \(String(format: "%.2f", price))"
        case .dailyMove(let percent): "\(symbol) moves ±\(String(format: "%g", percent))% in a day"
        }
    }
}

/// A radio stream the user added in Settings.
struct CustomRadioStation: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var streamURL: URL
}

/// User preferences edited in the Settings window (⌘,). Each value is saved as JSON in
/// UserDefaults as soon as it changes.
@MainActor
final class AppSettings: ObservableObject {
    @Published var weatherLocation: WeatherLocation { didSet { save(weatherLocation, Key.weatherLocation) } }
    @Published var temperatureUnit: TemperatureUnit { didSet { save(temperatureUnit, Key.temperatureUnit) } }
    @Published var watchlist: [WatchedSymbol] { didSet { save(watchlist, Key.watchlist) } }
    /// The symbol shown large with its intraday chart on the stock card.
    @Published var featuredSymbol: String { didSet { save(featuredSymbol, Key.featuredSymbol) } }
    @Published var clocks: [WorldClock] { didSet { save(clocks, Key.clocks) } }
    @Published var newsSources: [NewsSource] { didSet { save(newsSources, Key.newsSources) } }
    /// Minutes between news and weather refreshes.
    @Published var refreshMinutes: Int { didSet { save(refreshMinutes, Key.refreshMinutes) } }
    /// Widgets whose buttons are left out of the dashboard's top bar.
    @Published var hiddenFromTopBar: Set<WidgetKind> { didSet { save(hiddenFromTopBar, Key.hiddenFromTopBar) } }
    @Published var notifiesIncomingAlerts: Bool { didSet { save(notifiesIncomingAlerts, Key.notifiesIncomingAlerts) } }
    /// Only alerts for areas containing one of these are shown; empty means all areas.
    @Published var alertAreas: [String] { didSet { save(alertAreas, Key.alertAreas) } }
    @Published var priceAlerts: [PriceAlert] { didSet { save(priceAlerts, Key.priceAlerts) } }
    /// Built-in radio stations (by ID) that are hidden from the radio card.
    @Published var hiddenRadioStations: Set<String> { didSet { save(hiddenRadioStations, Key.hiddenRadioStations) } }
    @Published var customRadioStations: [CustomRadioStation] { didSet { save(customRadioStations, Key.customRadioStations) } }
    /// Sends 10 s of the playing station to Shazam every 90 s to name the song.
    @Published var recognizesSongs: Bool { didSet { save(recognizesSongs, Key.recognizesSongs) } }

    private let defaults: UserDefaults

    private enum Key {
        static let weatherLocation = "settings.weather-location.v1"
        static let temperatureUnit = "settings.temperature-unit.v1"
        static let watchlist = "settings.watchlist.v1"
        static let featuredSymbol = "settings.featured-symbol.v1"
        static let clocks = "settings.clocks.v1"
        static let newsSources = "settings.news-sources.v1"
        static let refreshMinutes = "settings.refresh-minutes.v1"
        static let hiddenFromTopBar = "settings.hidden-from-top-bar.v1"
        static let notifiesIncomingAlerts = "settings.notify-incoming-alerts.v1"
        static let alertAreas = "settings.alert-areas.v1"
        static let priceAlerts = "settings.price-alerts.v1"
        static let hiddenRadioStations = "settings.hidden-radio-stations.v1"
        static let customRadioStations = "settings.custom-radio-stations.v1"
        static let recognizesSongs = "settings.recognize-songs.v1"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func load<Value: Decodable>(_ key: String, _ fallback: Value) -> Value {
            defaults.data(forKey: key)
                .flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
                ?? fallback
        }
        weatherLocation = load(Key.weatherLocation, .austin)
        temperatureUnit = load(Key.temperatureUnit, .fahrenheit)
        let watchlist = load(Key.watchlist, WatchedSymbol.defaults)
        self.watchlist = watchlist.isEmpty ? WatchedSymbol.defaults : watchlist
        featuredSymbol = load(Key.featuredSymbol, watchlist.first?.symbol ?? "AMD")
        clocks = load(Key.clocks, WorldClock.defaults)
        newsSources = load(Key.newsSources, NewsSource.defaults)
        refreshMinutes = load(Key.refreshMinutes, 2)
        hiddenFromTopBar = load(Key.hiddenFromTopBar, [])
        notifiesIncomingAlerts = load(Key.notifiesIncomingAlerts, true)
        alertAreas = load(Key.alertAreas, [])
        priceAlerts = load(Key.priceAlerts, [])
        hiddenRadioStations = load(Key.hiddenRadioStations, [])
        customRadioStations = load(Key.customRadioStations, [])
        recognizesSongs = load(Key.recognizesSongs, true)
    }

    /// Returns the price alerts this quote sets off, removing one-shot alerts and
    /// marking daily-move alerts as fired for today.
    func firePriceAlerts(for quote: StockQuote, today: String) -> [PriceAlert] {
        let fired = priceAlerts.filter { $0.isTriggered(by: quote, today: today) }
        guard !fired.isEmpty else { return [] }
        let firedIDs = Set(fired.map(\.id))
        priceAlerts = priceAlerts.compactMap { alert in
            guard firedIDs.contains(alert.id) else { return alert }
            if alert.isOneShot { return nil }
            var repeating = alert
            repeating.lastFiredDay = today
            return repeating
        }
        return fired
    }

    /// Adds a symbol (normalized) unless it is already watched; returns it if added.
    @discardableResult
    func addSymbol(_ raw: String, assetClass: String? = nil) -> WatchedSymbol? {
        guard
            let symbol = WatchedSymbol.normalized(raw),
            !watchlist.contains(where: { $0.symbol == symbol })
        else { return nil }
        let entry = WatchedSymbol(symbol: symbol, assetClass: assetClass)
        watchlist.append(entry)
        return entry
    }

    func removeSymbol(_ symbol: String) {
        guard watchlist.count > 1 else { return }
        watchlist.removeAll { $0.symbol == symbol }
        if featuredSymbol == symbol, let first = watchlist.first {
            featuredSymbol = first.symbol
        }
    }

    /// Remembers which Nasdaq asset class answered for a symbol.
    func setAssetClass(_ assetClass: String, for symbol: String) {
        guard let index = watchlist.firstIndex(where: { $0.symbol == symbol }),
              watchlist[index].assetClass != assetClass else { return }
        watchlist[index].assetClass = assetClass
    }

    func addNewsSource(_ source: NewsSource) {
        guard !newsSources.contains(where: { $0.url == source.url }) else { return }
        newsSources.append(source)
    }

    private func save<Value: Encodable>(_ value: Value, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
