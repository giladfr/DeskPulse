import Foundation

enum DataService {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.requestCachePolicy = .reloadRevalidatingCacheData
        return URLSession(configuration: configuration)
    }()

    static func fetchAMDQuote() async -> AMDQuoteSnapshot? {
        let url = URL(
            string: "https://api.nasdaq.com/api/quote/AMD/info?assetclass=stocks"
        )!
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        guard
            let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = root["data"] as? [String: Any],
            let primary = payload["primaryData"] as? [String: Any]
        else { return nil }

        let marketStatus = payload["marketStatus"] as? String ?? "Unknown"
        let secondary = payload["secondaryData"] as? [String: Any]
        let useExtendedQuote = marketStatus.caseInsensitiveCompare("Open") != .orderedSame
            && marketNumber(secondary?["lastSalePrice"]) != nil
        let displayed = useExtendedQuote ? secondary! : primary
        guard
            let price = marketNumber(displayed["lastSalePrice"]),
            let change = marketNumber(displayed["netChange"]),
            let changePercent = marketNumber(displayed["percentageChange"])
        else { return nil }

        return AMDQuoteSnapshot(
            price: price,
            change: change,
            changePercent: changePercent,
            bid: marketNumber(primary["bidPrice"]),
            ask: marketNumber(primary["askPrice"]),
            volume: primary["volume"] as? String ?? "—",
            marketStatus: useExtendedQuote ? extendedStatus(at: Date()) : marketStatus,
            tradeTime: displayed["lastTradeTimestamp"] as? String ?? "",
            isRealTime: displayed["isRealTime"] as? Bool ?? false,
            isExtendedHours: useExtendedQuote
        )
    }

    static func fetchAMDSessionChart() async -> AMDSessionChart? {
        let url = URL(
            string: "https://api.nasdaq.com/api/quote/AMD/chart?assetclass=stocks"
        )!
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        guard
            let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = root["data"] as? [String: Any],
            let rows = payload["chart"] as? [[String: Any]]
        else { return nil }

        let points = rows.compactMap { row -> AMDChartPoint? in
            guard let milliseconds = row["x"] as? Double,
                  let price = row["y"] as? Double else { return nil }
            let timestamp = Date(timeIntervalSince1970: milliseconds / 1_000)
            let displayTime = (row["z"] as? [String: Any])?["dateTime"] as? String
            return AMDChartPoint(
                timestamp: timestamp,
                price: price,
                session: displayTime.flatMap(tradingSession(timeLabel:))
                    ?? tradingSession(at: timestamp)
            )
        }
        guard !points.isEmpty else { return nil }
        let previousClose = marketNumber(payload["previousClose"])
            ?? points.first!.price
        return AMDSessionChart(
            points: points,
            previousClose: previousClose,
            timeAsOf: payload["timeAsOf"] as? String ?? ""
        )
    }

    static func fetchWeather() async -> WeatherSnapshot? {
        // Austin city center. Open-Meteo requires no key and stores no personal location.
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=30.2672&longitude=-97.7431&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m&daily=weather_code,temperature_2m_max,temperature_2m_min&temperature_unit=fahrenheit&wind_speed_unit=mph&timezone=America%2FChicago&forecast_days=5")!
        guard let (data, _) = try? await session.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = root["current"] as? [String: Any],
              let temperature = current["temperature_2m"] as? Double,
              let feels = current["apparent_temperature"] as? Double,
              let humidity = current["relative_humidity_2m"] as? Int,
              let wind = current["wind_speed_10m"] as? Double,
              let code = current["weather_code"] as? Int else { return nil }
        let forecast = parseDailyForecast(root["daily"] as? [String: Any])
        return WeatherSnapshot(
            temperature: Int(temperature.rounded()),
            feelsLike: Int(feels.rounded()),
            description: weatherDescription(code),
            humidity: humidity,
            windMPH: Int(wind.rounded()),
            code: code,
            forecast: forecast
        )
    }

    private static func parseDailyForecast(_ daily: [String: Any]?) -> [DailyForecast] {
        guard
            let daily,
            let dates = daily["time"] as? [String],
            let highs = daily["temperature_2m_max"] as? [Double],
            let lows = daily["temperature_2m_min"] as? [Double],
            let codes = daily["weather_code"] as? [Int]
        else { return [] }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Chicago")
        formatter.dateFormat = "yyyy-MM-dd"
        let count = min(dates.count, highs.count, lows.count, codes.count)
        return (0..<count).compactMap { index in
            guard let date = formatter.date(from: dates[index]) else { return nil }
            return DailyForecast(
                date: date,
                high: Int(highs[index].rounded()),
                low: Int(lows[index].rounded()),
                code: codes[index]
            )
        }
        .dropFirst()
        .prefix(4)
        .map { $0 }
    }

    static func fetchFeed(_ url: URL) async -> [FeedItem] {
        guard let (data, _) = try? await session.data(from: url) else { return [] }
        return parseFeed(data)
    }

    /// Parses RSS `<item>` or Atom `<entry>` elements; keeps the first 20.
    static func parseFeed(_ data: Data) -> [FeedItem] {
        FeedParser().parse(data: data)
    }

    static func decodeHTMLEntities(_ value: String) -> String {
        var decoded = value
        // Ordered so results are deterministic. "&amp;" goes first so double-encoded
        // entities in some feeds (e.g. "&amp;quot;") decode fully, matching the
        // numeric pass below.
        let namedEntities: [(String, String)] = [
            ("&amp;", "&"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&nbsp;", "\u{00A0}"),
            ("&lt;", "<"),
            ("&gt;", ">")
        ]
        for (entity, replacement) in namedEntities {
            decoded = decoded.replacingOccurrences(of: entity, with: replacement)
        }

        guard let expression = try? NSRegularExpression(
            pattern: #"&#(?:x([0-9A-Fa-f]+)|([0-9]+));"#
        ) else { return decoded }

        let fullRange = NSRange(decoded.startIndex..., in: decoded)
        for match in expression.matches(in: decoded, range: fullRange).reversed() {
            let hexadecimalRange = match.range(at: 1)
            let decimalRange = match.range(at: 2)
            let number: UInt32?
            if hexadecimalRange.location != NSNotFound,
               let range = Range(hexadecimalRange, in: decoded) {
                number = UInt32(decoded[range], radix: 16)
            } else if decimalRange.location != NSNotFound,
                      let range = Range(decimalRange, in: decoded) {
                number = UInt32(decoded[range], radix: 10)
            } else {
                number = nil
            }
            guard let number, let scalar = UnicodeScalar(number),
                  let range = Range(match.range, in: decoded) else { continue }
            decoded.replaceSubrange(range, with: String(Character(scalar)))
        }
        return decoded
    }

    static func fetchLiveTVPlayerSource(channel: String) async -> LiveTVPlayerSource? {
        guard ["11", "12", "13", "cnn"].contains(channel) else { return nil }
        let pageURL = URL(string: "https://gurutv.online/ch\(channel).html")!
        guard let (data, _) = try? await session.data(from: pageURL),
              let html = String(data: data, encoding: .utf8)
        else { return nil }
        return parseLiveTVPlayerSource(html: html)
    }

    /// Finds the stream in a channel page: an HLS playlist in `m3u8Url`, or else the
    /// embedded player's `src`.
    static func parseLiveTVPlayerSource(html: String) -> LiveTVPlayerSource? {
        if let marker = html.range(of: "var m3u8Url = '"),
           let valueEnd = html[marker.upperBound...].firstIndex(of: "'") {
            let value = String(html[marker.upperBound..<valueEnd])
                .replacingOccurrences(of: "&amp;", with: "&")
            return URL(string: value).map(LiveTVPlayerSource.hls)
        }

        guard
            let playerStart = html.range(of: "class=\"videoplayer\""),
            let sourceStart = html.range(
                of: "src=\"",
                range: playerStart.upperBound..<html.endIndex
            )
        else { return nil }
        let valueStart = sourceStart.upperBound
        guard let valueEnd = html[valueStart...].firstIndex(of: "\"") else { return nil }
        let value = String(html[valueStart..<valueEnd])
            .replacingOccurrences(of: "&amp;", with: "&")
        return URL(string: value).map(LiveTVPlayerSource.web)
    }

    private static func weatherDescription(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1...3: "Partly cloudy"
        case 45, 48: "Foggy"
        case 51...67: "Rain"
        case 71...77: "Snow"
        case 80...82: "Showers"
        case 85, 86: "Snow showers"
        case 95...99: "Thunderstorms"
        default: "Current conditions"
        }
    }

    private static func marketNumber(_ value: Any?) -> Double? {
        guard let string = value as? String else { return value as? Double }
        let cleaned = string.filter { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(cleaned)
    }

    static func tradingSession(at date: Date) -> AMDTradingSession {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if minute < 9 * 60 + 30 { return .premarket }
        if minute >= 16 * 60 { return .afterHours }
        return .regular
    }

    static func tradingSession(timeLabel: String) -> AMDTradingSession? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "h:mm a 'ET'"
        guard let time = formatter.date(from: timeLabel) else { return nil }
        return tradingSession(at: time)
    }

    private static func extendedStatus(at date: Date) -> String {
        switch tradingSession(at: date) {
        case .premarket: "Pre-Market"
        case .regular: "Closed"
        case .afterHours: "After Hours"
        }
    }
}

private final class FeedParser: NSObject, XMLParserDelegate {
    private var items: [FeedItem] = []
    private var insideItem = false
    private var currentElement = ""
    private var title = ""
    private var link = ""
    private var date = ""

    func parse(data: Data) -> [FeedItem] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return Array(items.prefix(20))
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName.lowercased()
        if currentElement == "item" || currentElement == "entry" {
            insideItem = true
            title = ""; link = ""; date = ""
        } else if insideItem, currentElement == "link",
                  let href = attributeDict["href"] {
            link = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideItem else { return }
        switch currentElement {
        case "title": title += string
        case "link", "guid": if link.isEmpty { link += string }
        case "pubdate", "published", "updated": date += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let element = elementName.lowercased()
        if element == "item" || element == "entry" {
            let cleanTitle = DataService.decodeHTMLEntities(title)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanTitle.isEmpty {
                items.append(FeedItem(
                    title: cleanTitle,
                    link: URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
                    date: Self.parseDate(date)
                ))
            }
            insideItem = false
        }
        currentElement = ""
    }

    // Created once: formatters are expensive, and parsing is safe to share.
    nonisolated(unsafe) private static let isoFormatter = ISO8601DateFormatter()
    nonisolated(unsafe) private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let rfc822Formatters: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "dd MMM yyyy HH:mm:ss Z"
    ].map {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = $0
        return formatter
    }

    /// RSS uses RFC 822 dates (`pubDate`); Atom uses ISO 8601, sometimes with
    /// fractional seconds or a `Z` suffix.
    static func parseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = isoFormatter.date(from: trimmed) ?? isoFractionalFormatter.date(from: trimmed) {
            return date
        }
        return rfc822Formatters.lazy.compactMap { $0.date(from: trimmed) }.first
    }
}
