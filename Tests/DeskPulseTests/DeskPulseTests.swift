import JavaScriptCore
import XCTest
@testable import DeskPulse

@MainActor
final class DeskPulseTests: XCTestCase {
    func testWidgetKindsHaveUniqueIDs() {
        XCTAssertEqual(Set(WidgetKind.allCases.map(\.id)).count, WidgetKind.allCases.count)
    }

    func testDefaultLayoutContainsAllCoreWidgets() {
        let kinds = Set(DashboardModel.defaultWidgets.map(\.kind))
        XCTAssertEqual(kinds, [
            .gmail, .stocks, .clocks, .date, .weather,
            .ynet, .rotter, .whatsapp, .youtubeMusic, .liveTVAll, .radio
        ])
        XCTAssertTrue(Set(WidgetKind.available).isSuperset(of: kinds))
        XCTAssertFalse(WidgetKind.available.contains(.liveTV11), "retired cards can't be added")
    }

    func testFeedTitlesDecodeDoubleEncodedHebrewPunctuation() {
        XCTAssertEqual(
            DataService.decodeHTMLEntities("בכיר: &amp;#1523;בדיקה&amp;#1524;"),
            "בכיר: ׳בדיקה״"
        )
    }

    func testNamedEntityDecodingIsDeterministic() {
        XCTAssertEqual(DataService.decodeHTMLEntities("a &amp;lt; b &amp;quot;c&amp;quot;"), "a < b \"c\"")
        XCTAssertEqual(DataService.decodeHTMLEntities("Q&amp;A &lt;live&gt;"), "Q&A <live>")
    }

    func testFeedItemsKeepStableIdentityAcrossRefreshes() {
        let link = URL(string: "https://example.com/story")!
        let first = FeedItem(title: "Old title", link: link, date: nil)
        let refreshed = FeedItem(title: "Updated title", link: link, date: Date())
        XCTAssertEqual(first.id, refreshed.id)
    }

    // MARK: Red Alert

    func testParsesRedAlertMessages() throws {
        let message = """
        {"type":"ALERT","data":{"notificationId":"abc-1","time":1790000000,"threat":0,
         "isDrill":false,"cities":["תל אביב - יפו","רמת גן - מערב"]}}
        """
        let alert = try XCTUnwrap(RedAlert.parse(Data(message.utf8)))
        XCTAssertEqual(alert.id, "abc-1")
        XCTAssertEqual(alert.cities.count, 2)
        XCTAssertTrue(alert.title.contains("צבע אדום"))

        let drill = message.replacingOccurrences(of: "\"isDrill\":false", with: "\"isDrill\":true")
        XCTAssertNil(RedAlert.parse(Data(drill.utf8)), "drills are ignored")
        XCTAssertNil(RedAlert.parse(Data(#"{"type":"SYSTEM_MESSAGE","data":{}}"#.utf8)))
        XCTAssertNil(RedAlert.parse(Data("not json".utf8)))
    }

    /// Regression test for two 1.0 crashes: URLSession calls the pong handler on its own
    /// queue, and a handler Swift treated as main-actor isolated trapped there. A closed
    /// local port makes URLSession call the handler (with an error) off the main thread.
    func testKeepAlivePingHandlerRunsOffTheMainThread() async throws {
        let socket = URLSession.shared.webSocketTask(with: try XCTUnwrap(URL(string: "ws://127.0.0.1:9/")))
        socket.resume()
        let pongs = PongTracker()
        sendKeepAlivePing(socket, pongs: pongs)
        try await Task.sleep(for: .seconds(1.5))
        socket.cancel(with: .goingAway, reason: nil)
        // A failed ping is not an answer, so a dead connection gets noticed.
        XCTAssertEqual(pongs.unansweredPings, 1)
    }

    func testAnsweredPingResetsTheCount() {
        let pongs = PongTracker()
        pongs.pingSent()
        pongs.pingSent()
        XCTAssertEqual(pongs.unansweredPings, 2)
        pongs.pongReceived(URLError(.timedOut))
        XCTAssertEqual(pongs.unansweredPings, 2)
        pongs.pongReceived(nil)
        XCTAssertEqual(pongs.unansweredPings, 0)
    }

    func testRedAlertAreaFilter() {
        let alert = RedAlert(id: "1", threat: 0, cities: ["תל אביב - יפו", "חולון"], isDrill: false)
        XCTAssertTrue(alert.matches(areas: []), "no filter means every area")
        XCTAssertTrue(alert.matches(areas: ["תל אביב"]))
        XCTAssertFalse(alert.matches(areas: ["חיפה", "  "]))
    }

    func testRealAlertIsDeliveredAndTestAlertLeavesLayoutAlone() throws {
        let suite = "DeskPulseTests.alerts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DashboardModel(settings: AppSettings(defaults: defaults))
        try XCTSkipUnless(model.incomingAlertDetectionEnabled, "detection is off in this environment")

        let before = model.warActivationRequest
        model.sendTestAlert()
        XCTAssertEqual(model.latestIncomingAlert?.isTest, true)
        XCTAssertEqual(model.warActivationRequest, before)

        model.settings.alertAreas = ["חיפה"]
        model.handle(RedAlert(id: "2", threat: 0, cities: ["אשקלון"], isDrill: false))
        XCTAssertEqual(model.latestIncomingAlert?.isTest, true, "other areas are ignored")

        model.handle(RedAlert(id: "3", threat: 0, cities: ["חיפה - מערב"], isDrill: false))
        XCTAssertEqual(model.latestIncomingAlert?.areas, ["חיפה - מערב"])
        XCTAssertEqual(model.latestIncomingAlert?.isTest, false)
    }

    func testAlertAreaSummaryIsShort() {
        let alert = IncomingAlert(title: "t", areas: ["a", "b", "c", "d", "e", "f"], receivedAt: Date())
        XCTAssertEqual(alert.areaSummary, "a, b, c, d +2 more")
    }

    // MARK: Price alerts

    /// A quote whose regular session moved `percent` from a previous close of 100,
    /// with `price` as the latest trade.
    private func quote(_ symbol: String, price: Double, percent: Double) -> MarketQuote {
        MarketQuote(
            symbol: symbol, price: price, sessionPrice: 100 + percent, previousClose: 100,
            sparkline: [], sessionStart: nil, sessionEnd: nil
        )
    }

    func testPriceAlertConditions() {
        let above = PriceAlert(symbol: "NVDA", condition: .above(150))
        XCTAssertFalse(above.isTriggered(by: quote("NVDA", price: 149.99, percent: 0), today: "d"))
        XCTAssertTrue(above.isTriggered(by: quote("NVDA", price: 150, percent: 0), today: "d"))
        XCTAssertFalse(above.isTriggered(by: quote("AMD", price: 200, percent: 0), today: "d"))

        let below = PriceAlert(symbol: "AMD", condition: .below(100))
        XCTAssertTrue(below.isTriggered(by: quote("AMD", price: 99, percent: 0), today: "d"))

        var move = PriceAlert(symbol: "AMD", condition: .dailyMove(3))
        XCTAssertTrue(move.isTriggered(by: quote("AMD", price: 1, percent: -3.2), today: "d"))
        XCTAssertFalse(move.isTriggered(by: quote("AMD", price: 1, percent: 2.9), today: "d"))
        move.lastFiredDay = "d"
        XCTAssertFalse(move.isTriggered(by: quote("AMD", price: 1, percent: 5), today: "d"))
    }

    func testFiringPriceAlertsRemovesOneShotsAndMarksDailyMoves() throws {
        let suite = "DeskPulseTests.price.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.priceAlerts = [
            PriceAlert(symbol: "AMD", condition: .above(100)),
            PriceAlert(symbol: "AMD", condition: .dailyMove(2)),
            PriceAlert(symbol: "AMD", condition: .below(50))
        ]
        let fired = settings.firePriceAlerts(for: quote("AMD", price: 110, percent: 4), today: "2026-09-25")
        XCTAssertEqual(fired.count, 2)
        XCTAssertEqual(settings.priceAlerts.count, 2, "the above-100 alert is done")
        XCTAssertEqual(settings.priceAlerts.first?.lastFiredDay, "2026-09-25")
        XCTAssertTrue(settings.firePriceAlerts(for: quote("AMD", price: 110, percent: 4), today: "2026-09-25").isEmpty,
                      "daily moves fire once a day")
        XCTAssertEqual(AppSettings(defaults: defaults).priceAlerts.count, 2, "saved")
    }

    // MARK: Market data (Yahoo)

    func testSparkQuotesSeparateTheSessionFromExtendedHours() throws {
        let json = """
        {
          "AMD": {"symbol": "AMD", "start": 1000, "end": 2000, "previousClose": 562.23,
                  "chartPreviousClose": 562.23, "fulldayPrice": 547.65,
                  "timestamp": [1000, 1300, 1600], "close": [560.0, null, 528.75]},
          "TEVA.TA": {"symbol": "TEVA.TA", "start": 1000, "end": 5000, "chartPreviousClose": 12820,
                      "fulldayPrice": 12890, "timestamp": [1000, 1300], "close": [12850, 12880]},
          "NOPE": {"symbol": "NOPE", "close": null}
        }
        """
        let quotes = YahooFinance.parseSpark(Data(json.utf8), now: Date(timeIntervalSince1970: 3000))

        // After New York's close: the session is the 4 p.m. close, the rest is after hours.
        let amd = try XCTUnwrap(quotes["AMD"])
        XCTAssertEqual(amd.sessionPrice, 528.75)
        XCTAssertEqual(amd.price, 547.65)
        XCTAssertEqual(amd.sparkline, [560, 528.75], "gaps are skipped")
        XCTAssertEqual(amd.dayChangePercent, (528.75 - 562.23) / 562.23 * 100, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(amd.extendedChange), 18.9, accuracy: 1e-9)
        XCTAssertFalse(amd.isTrading(at: Date(timeIntervalSince1970: 3000)))

        // Still trading: the latest trade is the session price, with no extended move.
        let teva = try XCTUnwrap(quotes["TEVA.TA"])
        XCTAssertEqual(teva.sessionPrice, 12890)
        XCTAssertNil(teva.extendedChange)
        XCTAssertTrue(teva.isTrading(at: Date(timeIntervalSince1970: 3000)))
        // Agorot to shekels.
        XCTAssertEqual(teva.scaled(by: 0.01).price, 128.9, accuracy: 1e-9)
        XCTAssertEqual(teva.scaled(by: 0.01).dayChangePercent, teva.dayChangePercent, accuracy: 1e-9)

        XCTAssertNil(quotes["NOPE"])
    }

    private func chartJSON(
        currency: String = "USD",
        regularMarketTime: Double,
        closes: String = "[100, 101, 102, 103]",
        timestamps: String = "[900, 1100, 1500, 2100]"
    ) -> Data {
        Data("""
        {"chart": {"result": [{
          "meta": {"symbol": "X", "currency": "\(currency)", "fullExchangeName": "NasdaqGS",
                   "instrumentType": "EQUITY", "longName": "Example Corp, Inc.",
                   "regularMarketPrice": 99, "regularMarketTime": \(regularMarketTime),
                   "previousClose": 90, "chartPreviousClose": 90,
                   "regularMarketDayHigh": 104, "regularMarketDayLow": 98,
                   "fiftyTwoWeekHigh": 150, "fiftyTwoWeekLow": 50, "regularMarketVolume": 1200000,
                   "currentTradingPeriod": {"pre": {"start": 800, "end": 1000},
                                            "regular": {"start": 1000, "end": 2000},
                                            "post": {"start": 2000, "end": 3000}}},
          "timestamp": \(timestamps),
          "indicators": {"quote": [{"close": \(closes)}]}
        }]}}
        """.utf8)
    }

    func testDayChartSessionsAndDetails() throws {
        let (chart, details) = try XCTUnwrap(YahooFinance.parseChart(chartJSON(regularMarketTime: 1900), range: .day))
        XCTAssertEqual(chart.points.map(\.session), [.premarket, .regular, .regular, .afterHours])
        XCTAssertEqual(chart.baseline, 90, "during the day, the previous close")
        XCTAssertEqual(details.name, "Example Corp")
        XCTAssertEqual(details.currency, "USD")
        XCTAssertEqual(details.dayHigh, 104)
        XCTAssertEqual(details.yearLow, 50)
        XCTAssertEqual(details.regularStart, Date(timeIntervalSince1970: 1000))
    }

    /// Before the session, Yahoo's previous close is two sessions old; the last
    /// session's close is the right baseline for the pre-market chart.
    func testPreMarketChartComparesWithTheLastClose() throws {
        let (chart, _) = try XCTUnwrap(YahooFinance.parseChart(
            chartJSON(regularMarketTime: 500, closes: "[100, 101]", timestamps: "[850, 900]"),
            range: .day
        ))
        XCTAssertEqual(chart.baseline, 99)
        XCTAssertEqual(chart.points.map(\.session), [.premarket, .premarket])
    }

    func testTelAvivChartsAreConvertedFromAgorot() throws {
        let (chart, details) = try XCTUnwrap(YahooFinance.parseChart(
            chartJSON(currency: "ILA", regularMarketTime: 1900), range: .sixMonths
        ))
        XCTAssertEqual(details.currency, "ILS")
        XCTAssertEqual(details.priceScale, 0.01)
        XCTAssertEqual(details.currencySymbol, "₪")
        XCTAssertEqual(chart.points.map(\.price), [1, 1.01, 1.02, 1.03])
        XCTAssertEqual(chart.baseline, 0.9, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(details.yearHigh), 1.5, accuracy: 1e-9)
        XCTAssertTrue(chart.points.allSatisfy { $0.session == .regular }, "sessions only matter for one day")
    }

    func testSearchKeepsTradableSymbolsOnly() {
        let json = """
        {"quotes": [
          {"symbol": "TEVA", "longname": "Teva Pharmaceutical Industries", "exchDisp": "NYSE", "quoteType": "EQUITY"},
          {"symbol": "TEVA.TA", "shortname": "TEVA PHARMA IND", "exchDisp": "Tel Aviv", "quoteType": "EQUITY"},
          {"symbol": "TEVA261106C00041000", "shortname": "TEVA call", "quoteType": "OPTION"}
        ]}
        """
        let results = YahooFinance.parseSearch(Data(json.utf8))
        XCTAssertEqual(results.map(\.symbol), ["TEVA", "TEVA.TA"])
        XCTAssertEqual(results.last?.exchange, "Tel Aviv")
    }

    func testNasdaqFallbackOnlyForPlainUSTickers() {
        XCTAssertTrue(MarketData.isNasdaqSymbol("AMD"))
        XCTAssertFalse(MarketData.isNasdaqSymbol("TEVA.TA"))
        XCTAssertFalse(MarketData.isNasdaqSymbol("^GSPC"))
        XCTAssertFalse(MarketData.isNasdaqSymbol("ILS=X"))
    }

    func testMarketClockCountsDownToOpenAndClose() {
        let start = Date(timeIntervalSince1970: 10_000)
        let end = start.addingTimeInterval(6.5 * 3600)
        let before = MarketClock.status(now: start.addingTimeInterval(-(2 * 3600 + 5 * 60)), start: start, end: end)
        XCTAssertEqual(before.text, "opens in 2h 05m")
        XCTAssertFalse(before.isOpen)
        let during = MarketClock.status(now: end.addingTimeInterval(-45 * 60), start: start, end: end)
        XCTAssertEqual(during.text, "closes in 45m")
        XCTAssertTrue(during.isOpen)
        XCTAssertEqual(MarketClock.status(now: end, start: start, end: end).text, "closed")
        XCTAssertEqual(MarketClock.duration(30), "<1m")
        XCTAssertEqual(MarketClock.duration(50 * 3600), "2d 2h")
    }

    func testPortfolioCombinesDollarsAndShekels() throws {
        var amd = WatchedSymbol(symbol: "AMD")
        amd.shares = 10
        amd.averageCost = 100
        var teva = WatchedSymbol(symbol: "TEVA.TA")
        teva.shares = 100
        teva.averageCost = 100
        let amdQuote = MarketQuote(symbol: "AMD", price: 110, sessionPrice: 110, previousClose: 105,
                                   sparkline: [], sessionStart: nil, sessionEnd: nil)
        // ₪120 a share, up ₪2 today, at ₪4 to the dollar.
        let tevaQuote = MarketQuote(symbol: "TEVA.TA", price: 120, sessionPrice: 120, previousClose: 118,
                                    sparkline: [], sessionStart: nil, sessionEnd: nil)
        let summary = try XCTUnwrap(PortfolioSummary.make(
            positions: [(amd, amdQuote, "USD"), (teva, tevaQuote, "ILS")],
            shekelsPerDollar: 4
        ))
        XCTAssertEqual(summary.value, 1100 + 3000, accuracy: 1e-9)
        XCTAssertEqual(summary.dayChange, 50 + 50, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(summary.totalChange), 100 + 500, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(summary.totalChangePercent), 600.0 / 3500 * 100, accuracy: 1e-9)

        // Without a cost, there is no total; without a rate, shekel holdings are left out.
        amd.averageCost = nil
        let partial = try XCTUnwrap(PortfolioSummary.make(positions: [(amd, amdQuote, "USD"), (teva, tevaQuote, "ILS")], shekelsPerDollar: nil))
        XCTAssertEqual(partial.value, 1100, accuracy: 1e-9)
        XCTAssertNil(partial.totalChange)
        XCTAssertNil(PortfolioSummary.make(positions: [(teva, tevaQuote, "ILS")], shekelsPerDollar: nil))
    }

    func testPositionsAreSavedWithTheWatchlist() throws {
        let suite = "DeskPulseTests.positions.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.hasPositions)
        settings.setPosition("AMD", shares: nil, averageCost: 120)
        XCTAssertFalse(settings.hasPositions, "a cost alone is not a position, but it is kept")
        settings.setPosition("AMD", shares: 10, averageCost: 120)
        XCTAssertTrue(settings.hasPositions)
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.watchlist.first { $0.symbol == "AMD" }?.shares, 10)
        XCTAssertEqual(reloaded.watchlist.first { $0.symbol == "AMD" }?.averageCost, 120)
        XCTAssertEqual(reloaded.marketStrip, WatchedSymbol.marketStripDefaults)
        settings.setPosition("AMD", shares: 0, averageCost: nil)
        XCTAssertFalse(settings.hasPositions)
    }

    func testAlertLevelsComeFromPriceAlerts() {
        XCTAssertEqual(PriceAlert(symbol: "A", condition: .above(150)).priceLevel, 150)
        XCTAssertNil(PriceAlert(symbol: "A", condition: .dailyMove(3)).priceLevel)
    }

    // MARK: Trading widgets

    func testHeadlinesAreTaggedWithTheirSymbols() {
        let watched = ["AMD", "NVDA", "TEVA.TA"]
        XCTAssertEqual(TradingFeeds.tickers(in: "Nvidia and AMD rally as chip stocks rebound", watched: watched), ["AMD", "NVDA"])
        XCTAssertEqual(TradingFeeds.tickers(in: "$MU jumps after HBM guidance", watched: watched), ["MU"])
        XCTAssertEqual(TradingFeeds.tickers(in: "TSMC lifts capex; ASML orders climb", watched: watched), ["ASML", "TSM"])
        XCTAssertEqual(TradingFeeds.tickers(in: "Teva shares rise in Tel Aviv after TEVA results", watched: watched), ["TEVA.TA"])
        XCTAssertTrue(TradingFeeds.tickers(in: "Artificial intelligence spending to grow, on and on", watched: watched).isEmpty,
                      "short tickers like ON only count as $ON, and 'intelligence' is not Intel")
        XCTAssertTrue(TradingFeeds.tickers(in: "Intel's foundry wins a customer", watched: watched).contains("INTC"))
    }

    func testTechHeadlinesNeedWholeWords() {
        XCTAssertTrue(TradingFeeds.isTechHeadline("Chipmakers slide as export controls tighten"))
        XCTAssertTrue(TradingFeeds.isTechHeadline("AI capex: hyperscalers raise guidance"))
        XCTAssertFalse(TradingFeeds.isTechHeadline("Airlines cut capacity as aid talks stall"))
        XCTAssertFalse(TradingFeeds.isTechHeadline("Oil climbs to a five-month high"))
    }

    func testWireMergesNewestFirstWithoutRepeatsOrStaleStories() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-23T14:00:00Z"))
        let bloomberg = TradingFeeds.WireSource(id: "b", name: "Bloomberg", url: URL(string: "https://b.example")!, isTech: false)
        let cnbc = TradingFeeds.WireSource(id: "c", name: "CNBC", url: URL(string: "https://c.example")!, isTech: false)
        let items = TradingFeeds.mergeWire([
            (bloomberg, [
                FeedItem(title: "Nvidia hits a record", link: URL(string: "https://b.example/1?utm=rss"), date: now.addingTimeInterval(-600)),
                FeedItem(title: "Oil climbs", link: URL(string: "https://b.example/2"), date: now.addingTimeInterval(-60)),
                FeedItem(title: "An old story", link: URL(string: "https://b.example/3"), date: now.addingTimeInterval(-3 * 86400))
            ]),
            (cnbc, [
                FeedItem(title: "Nvidia hits a record!", link: URL(string: "https://c.example/9"), date: now.addingTimeInterval(-300)),
                FeedItem(title: "Same link, other title", link: URL(string: "https://b.example/1"), date: now)
            ])
        ], watched: ["NVDA"], now: now)
        XCTAssertEqual(items.map(\.title), ["Oil climbs", "Nvidia hits a record"])
        XCTAssertEqual(items.last?.tickers, ["NVDA"])
        XCTAssertTrue(try XCTUnwrap(items.last).isTech, "tagged headlines count as tech")
        XCTAssertFalse(try XCTUnwrap(items.first).isTech)
    }

    func testLiveVideoIsFoundOnlyWhenTheChannelIsLive() {
        XCTAssertEqual(
            TradingFeeds.parseLiveVideoID(html: #"<head><link rel="canonical" href="https://www.youtube.com/watch?v=QB5BNdBFujE"></head>"#),
            "QB5BNdBFujE"
        )
        XCTAssertNil(TradingFeeds.parseLiveVideoID(
            html: #"<link rel="canonical" href="https://www.youtube.com/channel/UCrp_UI8XtuYfpiqluWLD7Lw">"#
        ))
    }

    func testHeatmapCategoriesAreWellFormed() {
        let categories = TradingFeeds.heatmapCategories
        XCTAssertEqual(Set(categories.map(\.id)).count, categories.count, "unique IDs")
        XCTAssertFalse(categories.contains { $0.id == TradingFeeds.watchlistCategoryID })
        XCTAssertEqual(categories.first?.symbols, TradingFeeds.semiconductorSymbols, "semis first, as before")
        for category in categories {
            XCTAssertFalse(category.symbols.isEmpty, category.name)
            XCTAssertLessThanOrEqual(category.symbols.count, 20, "\(category.name): tiles stay at least as large as the semis'")
            XCTAssertEqual(Set(category.symbols).count, category.symbols.count, "\(category.name): no repeats")
            for symbol in category.symbols + category.benchmarks {
                XCTAssertEqual(WatchedSymbol.normalized(symbol), symbol, "\(category.name): \(symbol)")
            }
        }
    }

    func testEarningsAreParsedAndFilteredToRelevantNames() {
        let json = """
        {"data": {"rows": [
          {"symbol": "GOOGL", "name": "Alphabet Inc. Class A Common Stock", "time": "time-after-hours", "epsForecast": "$2.94", "marketCap": "$4,094,114,920,000"},
          {"symbol": "GOOG", "name": "Alphabet Inc. Class C Capital Stock", "time": "time-after-hours", "epsForecast": "$2.94", "marketCap": "$4,094,114,920,000"},
          {"symbol": "GEV", "name": "GE Vernova Inc.", "time": "time-pre-market", "epsForecast": "$4.03", "marketCap": "$246,603,596,000"},
          {"symbol": "TXN", "name": "Texas Instruments Incorporated", "time": "time-pre-market", "epsForecast": "", "marketCap": "$180,000,000,000"},
          {"symbol": "XYZQ", "name": "Watched Co", "time": "time-not-supplied", "epsForecast": "$0.10", "marketCap": "$1,000"}
        ]}}
        """
        let all = TradingFeeds.parseEarnings(Data(json.utf8), day: "2026-10-28")
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(all.first?.name, "Alphabet")
        XCTAssertEqual(all.first?.marketCap, 4_094_114_920_000)
        let relevant = TradingFeeds.relevantEarnings(all, watched: ["XYZQ"])
        XCTAssertEqual(relevant.map(\.symbol), ["TXN", "GOOGL", "XYZQ"], "before the open, then after the close by size, then unknown")
        XCTAssertNil(relevant.first?.epsEstimate)
        XCTAssertEqual(relevant.first?.time, .beforeOpen)
    }

    func testMacroCalendarKeepsUSEventsOfNote() throws {
        let json = """
        [
          {"title": "CPI m/m", "country": "USD", "date": "2026-10-23T08:30:00-04:00", "impact": "High", "forecast": "0.3%", "previous": "0.4%", "actual": ""},
          {"title": "Unemployment Claims", "country": "USD", "date": "2026-10-22T08:30:00-04:00", "impact": "Medium", "forecast": "200K", "previous": "199K", "actual": "195K"},
          {"title": "Building Permits", "country": "USD", "date": "2026-10-20T08:30:00-04:00", "impact": "Low", "forecast": "1.39M", "previous": "1.39M"},
          {"title": "German Ifo", "country": "EUR", "date": "2026-10-23T04:00:00-04:00", "impact": "High", "forecast": "", "previous": ""}
        ]
        """
        let events = TradingFeeds.parseMacro(Data(json.utf8))
        XCTAssertEqual(events.map(\.title), ["CPI m/m", "Unemployment Claims"])
        XCTAssertEqual(events.first?.impact, .high)
        XCTAssertNil(events.first?.actual, "an empty actual is not yet released")
        XCTAssertEqual(events.last?.actual, "195K")
        XCTAssertEqual(events.first?.date, try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-23T12:30:00Z")))
    }

    @MainActor
    func testEarningsDaysSkipWeekends() throws {
        // Friday 23 October 2026, 10:00 New York.
        let friday = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-23T14:00:00Z"))
        XCTAssertEqual(
            MarketCalendarModel.reportingDays(from: friday),
            ["2026-10-23", "2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30"]
        )
    }

    // MARK: Radio stations

    func testRadioStationListFollowsSettings() {
        let custom = CustomRadioStation(name: "KUTX", streamURL: URL(string: "https://example.com/kutx")!)
        let stations = RadioStation.stations(hiding: ["galatz", "eco99"], adding: [custom])
        XCTAssertFalse(stations.contains { $0.id == "galatz" })
        XCTAssertEqual(stations.last?.name, "KUTX")
        XCTAssertEqual(stations.count, RadioStation.all.count - 2 + 1)
        XCTAssertEqual(
            RadioStation.stations(hiding: Set(RadioStation.all.map(\.id)), adding: []).count,
            RadioStation.all.count,
            "hiding everything falls back to the built-in list"
        )
    }

    func testTradingSessionBoundariesUseEasternTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        func date(hour: Int, minute: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(
                year: 2026, month: 7, day: 29, hour: hour, minute: minute
            )))
        }

        XCTAssertEqual(DataService.tradingSession(at: try date(hour: 9, minute: 29)), .premarket)
        XCTAssertEqual(DataService.tradingSession(at: try date(hour: 9, minute: 30)), .regular)
        XCTAssertEqual(DataService.tradingSession(at: try date(hour: 15, minute: 59)), .regular)
        XCTAssertEqual(DataService.tradingSession(at: try date(hour: 16, minute: 0)), .afterHours)
    }

    func testWeekendsAndClosedMarketsShowTheWholeLastSession() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        // Saturday 3 October 2026, 12:00 New York: "regular hours" by the clock alone.
        let saturdayNoon = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 3, hour: 12
        )))
        XCTAssertTrue(DataService.isMarketWeekend(saturdayNoon))
        XCTAssertEqual(DataService.extendedStatus(at: saturdayNoon), "Closed")
        let saturdayEvening = saturdayNoon.addingTimeInterval(6 * 3600)
        XCTAssertEqual(DataService.extendedStatus(at: saturdayEvening), "Closed", "not After Hours")

        // A weekday holiday: the clock says regular hours, Nasdaq says closed.
        let holidayNoon = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 26, hour: 12
        )))
        XCTAssertFalse(DataService.isMarketWeekend(holidayNoon))
    }

    func testWeatherCodesHaveMatchingIconsAndDescriptions() {
        XCTAssertEqual(DataService.weatherSymbol(73), "cloud.snow.fill")
        XCTAssertEqual(DataService.weatherSymbol(86), "cloud.snow.fill")
        XCTAssertEqual(DataService.weatherSymbol(53), "cloud.drizzle.fill")
        XCTAssertEqual(DataService.weatherSymbol(66), "cloud.sleet.fill")
        XCTAssertEqual(DataService.weatherSymbol(63), "cloud.rain.fill")
        XCTAssertEqual(DataService.weatherDescription(73), "Snow")
        XCTAssertEqual(DataService.weatherDescription(53), "Drizzle")
        XCTAssertEqual(DataService.weatherDescription(67), "Freezing rain")
    }

    func testNasdaqChartLabelsDetermineTradingSession() {
        XCTAssertEqual(DataService.tradingSession(timeLabel: "4:00 AM ET"), .premarket)
        XCTAssertEqual(DataService.tradingSession(timeLabel: "9:29 AM ET"), .premarket)
        XCTAssertEqual(DataService.tradingSession(timeLabel: "9:30 AM ET"), .regular)
        XCTAssertEqual(DataService.tradingSession(timeLabel: "4:00 PM ET"), .afterHours)
    }

    func testCompactDefaultWidgetsShareTheSameHeight() {
        let heights = Set(
            DashboardModel.defaultWidgets
                .filter { DashboardModel.compactTopRowKinds.contains($0.kind) }
                .map(\.height)
        )
        XCTAssertEqual(heights.count, 1)
        XCTAssertEqual(heights.first, 170)
    }

    func testTidyLayoutPreservesTopologyAndNormalizesRow() {
        let topLeft = DashboardWidget(
            id: UUID(), kind: .clocks,
            x: 13, y: 15, width: 501, height: 181
        )
        let topMiddle = DashboardWidget(
            id: UUID(), kind: .date,
            x: 535, y: 18, width: 225, height: 174
        )
        let topRight = DashboardWidget(
            id: UUID(), kind: .weather,
            x: 779, y: 14, width: 229, height: 185
        )
        let tidied = DashboardModel.tidiedLayout(
            [topLeft, topMiddle, topRight],
            hiddenKinds: [],
            canvasSize: CGSize(width: 1024, height: 700)
        )

        XCTAssertEqual(Set(tidied.map(\.y)).count, 1)
        XCTAssertEqual(Set(tidied.map(\.height)).count, 1)
        XCTAssertEqual(tidied[1].x - (tidied[0].x + tidied[0].width), 16)
        XCTAssertEqual(tidied[2].x - (tidied[1].x + tidied[1].width), 16)
        XCTAssertEqual(tidied[2].x + tidied[2].width, 1008)
        XCTAssertEqual(tidied.map(\.kind), [.clocks, .date, .weather])
    }

    func testTidyLayoutDoesNotEqualizeVeryDifferentContentHeights() {
        let mail = DashboardWidget(
            id: UUID(), kind: .gmail,
            x: 16, y: 240, width: 480, height: 320
        )
        let news = DashboardWidget(
            id: UUID(), kind: .ynet,
            x: 520, y: 248, width: 480, height: 640
        )
        let tidied = DashboardModel.tidiedLayout(
            [mail, news],
            hiddenKinds: [],
            canvasSize: CGSize(width: 1200, height: 900)
        )
        XCTAssertNotEqual(tidied[0].height, tidied[1].height)
    }

    func testLayoutSnapshotRoundTripsVisibilityAndGeometry() throws {
        let widget = DashboardWidget(
            id: UUID(), kind: .weather,
            x: 12, y: 24, width: 320, height: 180
        )
        let snapshot = DashboardLayoutSnapshot(
            widgets: [widget],
            hiddenKinds: [.gmail, .stocks]
        )
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(
            try JSONDecoder().decode(DashboardLayoutSnapshot.self, from: data),
            snapshot
        )
    }

    // MARK: HDMI black-bar crop

    private func detect(
        width: Int,
        height: Int,
        luma: (Int, Int) -> UInt8
    ) -> LetterboxDetector.Result {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { bytes[y * width + x] = luma(x, y) }
        }
        return bytes.withUnsafeBytes {
            LetterboxDetector.detect(in: LumaImage(
                width: width, height: height, bytesPerRow: width, bytes: $0
            ))
        }
    }

    private func assertRect(
        _ result: LetterboxDetector.Result,
        _ expected: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .content(let rect) = result else {
            return XCTFail("Expected content, got \(result)", file: file, line: line)
        }
        XCTAssertEqual(rect.minX, expected.minX, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(rect.minY, expected.minY, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(rect.width, expected.width, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(rect.height, expected.height, accuracy: 1e-6, file: file, line: line)
    }

    func testDetectsPillarboxedSixteenByTenPictureAndSnapsToExactShape() {
        // 16:10 inside 16:9 (like 1920×1200 inside 1920×1080), with 9 px bars.
        let result = detect(width: 192, height: 108) { x, _ in
            (9..<183).contains(x) ? 200 : 16
        }
        assertRect(result, CGRect(x: 0.05, y: 0, width: 0.9, height: 1))
    }

    func testFrameWithoutBarsIsFullFrame() {
        assertRect(detect(width: 192, height: 108) { _, _ in 120 }, LetterboxDetector.fullFrame)
    }

    func testBlankFrameIsReportedAsBlank() {
        XCTAssertEqual(detect(width: 192, height: 108) { _, _ in 16 }, .blank)
    }

    func testLopsidedDarkEdgeIsNotTreatedAsBars() {
        let result = detect(width: 192, height: 108) { x, _ in x < 20 ? 16 : 200 }
        XCTAssertEqual(result, .uncertain)
    }

    func testDarkDesktopWithMenuBarIsNotCropped() {
        // Dark wallpaper edges, but a bright menu bar spans the full width.
        let result = detect(width: 192, height: 108) { x, y in
            y < 3 || (40..<150).contains(x) ? 220 : 18
        }
        assertRect(result, LetterboxDetector.fullFrame)
    }

    func testCenteredRectForSixteenByTenInsideSixteenByNine() {
        let rect = LetterboxDetector.centeredRect(
            aspect: 16.0 / 10,
            in: CGSize(width: 1920, height: 1080)
        )
        XCTAssertEqual(rect.minX, 0.05, accuracy: 1e-9)
        XCTAssertEqual(rect.width, 0.9, accuracy: 1e-9)
        XCTAssertEqual(rect.height, 1, accuracy: 1e-9)
    }

    func testPreviewFramePlacesPictureExactlyOnScreen() {
        let bounds = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let frameSize = CGSize(width: 1920, height: 1080)
        let content = CGRect(x: 0.05, y: 0, width: 0.9, height: 1)

        // Fit: the 1728×1080 picture is scaled by 0.875 to span the full width.
        let fit = CaptureGeometry.previewFrame(
            bounds: bounds, frameSize: frameSize, content: content, fills: false
        )
        XCTAssertEqual(fit.width, 1680, accuracy: 1e-6)
        XCTAssertEqual(fit.height, 945, accuracy: 1e-6)
        XCTAssertEqual(fit.minX, -84, accuracy: 1e-6)
        XCTAssertEqual(fit.minY, 18.5, accuracy: 1e-6)
        // The bars land exactly outside the screen's left and right edges.
        XCTAssertEqual(fit.minX + fit.width * content.minX, 0, accuracy: 1e-6)
        XCTAssertEqual(fit.minX + fit.width * content.maxX, 1512, accuracy: 1e-6)

        // Fill: scaled to the full height, trimming only the picture's sides.
        let fill = CaptureGeometry.previewFrame(
            bounds: bounds, frameSize: frameSize, content: content, fills: true
        )
        XCTAssertEqual(fill.height, 982, accuracy: 1e-6)
        XCTAssertEqual(fill.minY, 0, accuracy: 1e-6)
        XCTAssertEqual(fill.midX, bounds.midX, accuracy: 1e-6)
    }

    func testShapeNamesForCommonPictures() {
        XCTAssertEqual(CaptureGeometry.shapeName(width: 1728, height: 1080), "16:10")
        XCTAssertEqual(CaptureGeometry.shapeName(width: 1920, height: 1080), "16:9")
        XCTAssertNil(CaptureGeometry.shapeName(width: 1000, height: 1000))
    }

    // MARK: Feed parsing

    func testParsesRSSItemsSkippingEmptyTitles() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><title>Channel title is not an item</title>
          <item>
            <title>First &amp;amp; best</title>
            <link>https://example.com/a</link>
            <pubDate>Thu, 24 Sep 2026 10:15:00 +0300</pubDate>
          </item>
          <item><title>   </title><link>https://example.com/empty</link></item>
          <item><title>Second</title><guid>https://example.com/b</guid></item>
        </channel></rss>
        """
        let items = DataService.parseFeed(Data(xml.utf8))
        XCTAssertEqual(items.map(\.title), ["First & best", "Second"])
        XCTAssertEqual(items.map(\.link), [
            URL(string: "https://example.com/a"),
            URL(string: "https://example.com/b")
        ])
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-24T07:15:00Z"))
        XCTAssertEqual(items.first?.date, expected)
        XCTAssertNil(items.last?.date)
    }

    /// XMLParser hands over text in pieces, split at every entity, so a link with
    /// "&amp;" used to keep only the part before it.
    func testFeedLinksKeepEverythingAfterAnAmpersand() {
        let xml = """
        <rss version="2.0"><channel>
          <item>
            <title>Story</title>
            <guid isPermaLink="false">story-123</guid>
            <link>https://example.com/a?at_medium=RSS&amp;at_campaign=rss</link>
          </item>
          <item><title>Only an ID</title><guid isPermaLink="false">story-456</guid></item>
        </channel></rss>
        """
        let items = DataService.parseFeed(Data(xml.utf8))
        XCTAssertEqual(items.first?.link, URL(string: "https://example.com/a?at_medium=RSS&at_campaign=rss"))
        XCTAssertNil(items.last?.link, "a GUID that isn't a web address is not a link")
    }

    func testAtomPrefersTheAlternateLink() {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><entry>
          <title>Entry</title>
          <link rel="self" href="https://example.com/api/entry"/>
          <link rel="alternate" href="https://example.com/entry"/>
        </entry></feed>
        """
        XCTAssertEqual(DataService.parseFeed(Data(xml.utf8)).first?.link, URL(string: "https://example.com/entry"))
    }

    func testParsesAtomEntriesWithISODates() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Feed</title>
          <updated>2026-09-24T09:00:00Z</updated>
          <entry>
            <title>Atom story</title>
            <link href="https://example.com/atom"/>
            <updated>2026-09-24T07:15:00Z</updated>
          </entry>
          <entry>
            <title>Fractional seconds</title>
            <link href="https://example.com/fractional"/>
            <published>2026-09-24T07:15:00.250Z</published>
          </entry>
        </feed>
        """
        let items = DataService.parseFeed(Data(xml.utf8))
        XCTAssertEqual(items.map(\.title), ["Atom story", "Fractional seconds"])
        XCTAssertEqual(items.first?.link, URL(string: "https://example.com/atom"))
        let whole = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-24T07:15:00Z"))
        XCTAssertEqual(items.first?.date, whole)
        let fractional = try XCTUnwrap(items.last?.date)
        XCTAssertEqual(fractional.timeIntervalSince(whole), 0.25, accuracy: 0.001)
    }

    func testMalformedFeedYieldsNoItemsInsteadOfCrashing() {
        XCTAssertTrue(DataService.parseFeed(Data("<html>not a feed".utf8)).isEmpty)
    }

    // MARK: Live TV page scraping

    func testLiveTVPageWithHLSPlaylist() {
        let html = "<script>var m3u8Url = 'https://cdn.example.com/live.m3u8?a=1&amp;b=2';</script>"
        XCTAssertEqual(
            DataService.parseLiveTVPlayerSource(html: html),
            .hls(URL(string: "https://cdn.example.com/live.m3u8?a=1&b=2")!)
        )
    }

    func testLiveTVPageWithEmbeddedPlayer() {
        let html = """
        <div><iframe class="videoplayer" allowfullscreen src="https://player.example.com/embed?x=1&amp;y=2"></iframe></div>
        """
        XCTAssertEqual(
            DataService.parseLiveTVPlayerSource(html: html),
            .web(URL(string: "https://player.example.com/embed?x=1&y=2")!)
        )
    }

    func testLiveTVPageWithoutPlayerIsNil() {
        XCTAssertNil(DataService.parseLiveTVPlayerSource(html: "<html><body>Offline</body></html>"))
    }

    // MARK: Situation layout upgrade

    func testOldSituationLayoutSwapsChannel13ForCNNLive() {
        let channel13 = DashboardWidget(id: UUID(), kind: .liveTV13, x: 1, y: 2, width: 300, height: 200)
        let upgraded = DashboardModel.normalizedWarSnapshot(DashboardLayoutSnapshot(
            widgets: [channel13],
            hiddenKinds: [.liveTVCNN]
        ))
        XCTAssertEqual(upgraded.widgets.map(\.kind), [.liveTVCNN])
        XCTAssertEqual(upgraded.widgets.first?.x, 1)
        XCTAssertTrue(upgraded.hiddenKinds.contains(.liveTV13))
        XCTAssertFalse(upgraded.hiddenKinds.contains(.liveTVCNN))
    }

    func testCurrentSituationLayoutKeepsItsWidgets() {
        let cnn = DashboardWidget(id: UUID(), kind: .liveTVCNN, x: 0, y: 0, width: 300, height: 200)
        let channel13 = DashboardWidget(id: UUID(), kind: .liveTV13, x: 0, y: 0, width: 300, height: 200)
        let snapshot = DashboardLayoutSnapshot(widgets: [cnn, channel13], hiddenKinds: [.liveTV13])
        XCTAssertEqual(DashboardModel.normalizedWarSnapshot(snapshot), snapshot)
    }

    // MARK: Live TV

    private func widget(_ kind: WidgetKind, _ x: Double, _ y: Double, _ width: Double, _ height: Double) -> DashboardWidget {
        DashboardWidget(id: UUID(), kind: kind, x: x, y: y, width: width, height: height)
    }

    /// The situation layout's Kan 11 and Channel 12 become one card across both;
    /// CNN Live keeps its own card.
    func testAdjacentTVCardsBecomeOneCardAcrossThem() throws {
        let snapshot = DashboardLayoutSnapshot(
            widgets: [
                widget(.liveTV11, 16, 192, 400, 224),
                widget(.liveTV, 432, 192, 400, 224),
                widget(.liveTVCNN, 848, 192, 400, 224),
                widget(.liveTV13, 0, 0, 300, 200),
                widget(.radio, 1264, 192, 430, 224)
            ],
            hiddenKinds: [.liveTV13]
        )
        let upgraded = DashboardModel.consolidatingLiveTV(snapshot)
        let tv = try XCTUnwrap(upgraded.widgets.first { $0.kind == .liveTVAll })
        XCTAssertEqual([tv.x, tv.y, tv.width, tv.height], [16, 192, 816, 224])
        XCTAssertFalse(upgraded.hiddenKinds.contains(.liveTVAll))
        XCTAssertTrue(upgraded.hiddenKinds.isSuperset(of: [.liveTV11, .liveTV, .liveTV13]))
        XCTAssertFalse(upgraded.hiddenKinds.contains(.liveTVCNN), "CNN Live is not Israeli TV")
        XCTAssertFalse(upgraded.hiddenKinds.contains(.radio))
        XCTAssertEqual(DashboardModel.consolidatingLiveTV(upgraded), upgraded, "upgrading twice changes nothing")
    }

    func testScatteredTVCardsGiveTheLargestSpot() throws {
        let snapshot = DashboardLayoutSnapshot(
            widgets: [
                widget(.liveTV, 128, 192, 720, 416),
                widget(.liveTV11, 928, 752, 384, 224),
                widget(.liveTVCNN, 1328, 752, 368, 208)
            ],
            hiddenKinds: []
        )
        let tv = try XCTUnwrap(DashboardModel.consolidatingLiveTV(snapshot).widgets.first { $0.kind == .liveTVAll })
        XCTAssertEqual([tv.x, tv.y, tv.width, tv.height], [128, 192, 720, 416])
    }

    func testLayoutWithoutTVKeepsTheCombinedCardHidden() {
        let snapshot = DashboardLayoutSnapshot(widgets: [widget(.ynet, 0, 0, 300, 300)], hiddenKinds: [.liveTVAll])
        let upgraded = DashboardModel.consolidatingLiveTV(snapshot)
        XCTAssertTrue(upgraded.hiddenKinds.contains(.liveTVAll))
        XCTAssertEqual(upgraded.widgets, snapshot.widgets)
    }

    /// The generated scripts must at least parse; a stray quote silently breaks a player.
    func testGeneratedPlayerScriptsParse() throws {
        let html = LiveTVWidget.hlsPlayerHTML(
            url: try XCTUnwrap(URL(string: "https://example.com/live.m3u8?a=1&b=2")),
            label: "Channel 13",
            muted: true
        )
        let script = try XCTUnwrap(html.components(separatedBy: "<script>").last?.components(separatedBy: "</script>").first)
        for source in [script, EmbeddedWebView.muteOnFirstPlayScript] {
            let context = try XCTUnwrap(JSContext())
            var error: String?
            context.exceptionHandler = { _, exception in error = exception?.toString() }
            // Wrapped in a function that is never called: parsed, not run.
            context.evaluateScript("(function () {\n\(source)\n})")
            XCTAssertNil(error)
        }
        XCTAssertTrue(html.contains("muted"))
        XCTAssertFalse(LiveTVWidget.hlsPlayerHTML(url: try XCTUnwrap(URL(string: "https://e.x/a.m3u8")), label: "Kan 11", muted: false)
            .contains("autoplay playsinline muted"))
    }

    func testSplitScreenFitsTheCardShape() {
        XCTAssertTrue(LiveTVHubWidget.bestGrid(count: 4, in: CGSize(width: 1232, height: 190), gap: 4) == (4, 1), "a wide strip")
        XCTAssertTrue(LiveTVHubWidget.bestGrid(count: 4, in: CGSize(width: 720, height: 400), gap: 4) == (2, 2), "a 16:9 card")
        XCTAssertTrue(LiveTVHubWidget.bestGrid(count: 4, in: CGSize(width: 400, height: 900), gap: 4) == (1, 4), "a tall column")
    }

    // MARK: Stocks

    func testSymbolsAreNormalized() {
        XCTAssertEqual(WatchedSymbol.normalized(" nasdaq:amd "), "AMD")
        XCTAssertEqual(WatchedSymbol.normalized("brk.b"), "BRK.B")
        XCTAssertEqual(WatchedSymbol.normalized("^gspc"), "^GSPC")
        XCTAssertEqual(WatchedSymbol.normalized("ils=x"), "ILS=X")
        XCTAssertEqual(WatchedSymbol.normalized("teva.ta"), "TEVA.TA")
        XCTAssertNil(WatchedSymbol.normalized("   "))
        XCTAssertNil(WatchedSymbol.normalized("!!!"))
    }

    func testCompanyNamesDropListingBoilerplate() {
        XCTAssertEqual(DataService.cleanCompanyName("Advanced Micro Devices, Inc. Common Stock"), "Advanced Micro Devices")
        XCTAssertEqual(DataService.cleanCompanyName("Alphabet Inc. Class A Common Stock"), "Alphabet")
        XCTAssertEqual(
            DataService.cleanCompanyName("Taiwan Semiconductor Manufacturing Company Ltd. American Depositary Shares"),
            "Taiwan Semiconductor Manufacturing Company"
        )
        XCTAssertEqual(DataService.cleanCompanyName("iShares Semiconductor ETF"), "iShares Semiconductor ETF")
    }

    func testParsesRegularSessionQuote() throws {
        let payload: [String: Any] = [
            "companyName": "NVIDIA Corporation Common Stock",
            "marketStatus": "Open",
            "primaryData": [
                "lastSalePrice": "$123.45",
                "netChange": "-1.50",
                "percentageChange": "-1.20%",
                "bidPrice": "$123.40",
                "askPrice": "$123.50",
                "volume": "1,000,000",
                "isRealTime": true,
                "lastTradeTimestamp": "Sep 25, 2026 10:00 AM ET"
            ]
        ]
        let quote = try XCTUnwrap(DataService.parseQuote(payload, symbol: "NVDA"))
        XCTAssertEqual(quote.symbol, "NVDA")
        XCTAssertEqual(quote.name, "NVIDIA")
        XCTAssertEqual(quote.price, 123.45, accuracy: 1e-9)
        XCTAssertEqual(quote.change, -1.5, accuracy: 1e-9)
        XCTAssertEqual(quote.changePercent, -1.2, accuracy: 1e-9)
        XCTAssertEqual(quote.bid ?? 0, 123.40, accuracy: 1e-9)
        XCTAssertFalse(quote.isExtendedHours)
        XCTAssertEqual(quote.marketStatus, "Open")
    }

    func testClosedMarketQuoteUsesExtendedHoursPrice() throws {
        let payload: [String: Any] = [
            "companyName": "Advanced Micro Devices, Inc. Common Stock",
            "marketStatus": "Closed",
            "primaryData": ["lastSalePrice": "$150.00", "netChange": "+2.00", "percentageChange": "+1.35%"],
            "secondaryData": ["lastSalePrice": "$151.00", "netChange": "+1.00", "percentageChange": "+0.67%"]
        ]
        let quote = try XCTUnwrap(DataService.parseQuote(payload, symbol: "AMD"))
        XCTAssertTrue(quote.isExtendedHours)
        XCTAssertEqual(quote.price, 151, accuracy: 1e-9)
    }

    func testQuoteWithoutPriceIsRejected() {
        XCTAssertNil(DataService.parseQuote(["primaryData": ["lastSalePrice": "N/A"]], symbol: "X"))
        XCTAssertNil(DataService.parseQuote([:], symbol: "X"))
    }

    func testParsesIntradayChart() throws {
        let payload: [String: Any] = [
            "previousClose": "$100.00",
            "timeAsOf": "Sep 25, 2026",
            "chart": [
                ["x": 1_790_000_000_000.0, "y": 99.5, "z": ["dateTime": "9:00 AM ET"]],
                ["x": 1_790_002_000_000.0, "y": 101.25, "z": ["dateTime": "10:00 AM ET"]],
                ["x": "bad", "y": 1.0]
            ]
        ]
        let chart = try XCTUnwrap(DataService.parseChart(payload))
        XCTAssertEqual(chart.previousClose, 100, accuracy: 1e-9)
        XCTAssertEqual(chart.points.map(\.price), [99.5, 101.25])
        XCTAssertEqual(chart.points.map(\.session), [.premarket, .regular])
    }

    // MARK: Weather locations

    func testParsesGeocodingResults() {
        let json = """
        {"results": [
          {"name": "Tel Aviv", "latitude": 32.08, "longitude": 34.78, "timezone": "Asia/Jerusalem",
           "admin1": "Tel Aviv District", "country": "Israel"},
          {"name": "Nowhere", "latitude": 1.0}
        ]}
        """
        let locations = DataService.parseLocations(Data(json.utf8))
        XCTAssertEqual(locations, [WeatherLocation(
            name: "Tel Aviv, Tel Aviv District, Israel",
            latitude: 32.08,
            longitude: 34.78,
            timeZone: "Asia/Jerusalem"
        )])
    }

    // MARK: News

    func testGoogleNewsTopicFeed() throws {
        let source = try XCTUnwrap(NewsSource.googleNews(topic: " semiconductors "))
        XCTAssertEqual(source.name, "semiconductors")
        XCTAssertEqual(source.url.host(), "news.google.com")
        let query = try XCTUnwrap(URLComponents(url: source.url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "q" }?.value, "semiconductors when:1d")
        XCTAssertNil(NewsSource.googleNews(topic: "   "))
    }

    func testNewsIsMergedNewestFirstWithoutDuplicates() {
        let bbc = NewsSource(name: "BBC", url: URL(string: "https://bbc.example/rss")!)
        let hn = NewsSource(name: "HN", url: URL(string: "https://hn.example/rss")!)
        func item(_ title: String, _ link: String, _ minutesAgo: Double?) -> FeedItem {
            FeedItem(
                title: title,
                link: URL(string: link),
                date: minutesAgo.map { Date(timeIntervalSinceNow: -$0 * 60) }
            )
        }
        let merged = DashboardModel.mergeNews([
            (bbc, [item("Old", "https://x/1", 60), item("Undated", "https://x/2", nil)]),
            (hn, [item("New", "https://x/3", 5), item("Old again", "https://x/1", 60)])
        ])
        XCTAssertEqual(merged.map(\.item.title), ["New", "Old", "Undated"])
        XCTAssertEqual(merged.first?.sourceName, "HN")
    }

    func testDetectsRightToLeftHeadlines() {
        XCTAssertTrue("צבע אדום באשקלון".containsRightToLeftText)
        XCTAssertTrue("خبر عاجل".containsRightToLeftText)
        XCTAssertFalse("Markets rally".containsRightToLeftText)
    }

    // MARK: Settings

    func testSettingsPersistAndEditWatchlist() throws {
        let suite = "DeskPulseTests.settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.watchlist, WatchedSymbol.defaults)
        XCTAssertEqual(settings.featuredSymbol, "AMD")
        XCTAssertNotNil(settings.addSymbol("msft", assetClass: "stocks"))
        XCTAssertNil(settings.addSymbol("MSFT"), "duplicates are ignored")
        settings.featuredSymbol = "MSFT"
        settings.removeSymbol("MSFT")
        XCTAssertEqual(settings.featuredSymbol, "AMD", "removing the featured symbol features the first")
        settings.setAssetClass("etf", for: "SOXX")
        settings.weatherLocation = WeatherLocation(name: "Haifa", latitude: 32.8, longitude: 35.0, timeZone: "Asia/Jerusalem")
        settings.temperatureUnit = .celsius

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.watchlist.map(\.symbol), ["AMD", "NVDA", "AVGO", "TSM", "SOXX"])
        XCTAssertEqual(reloaded.watchlist.last?.assetClass, "etf")
        XCTAssertEqual(reloaded.weatherLocation.name, "Haifa")
        XCTAssertEqual(reloaded.temperatureUnit, .celsius)
        XCTAssertEqual(reloaded.clocks.map(\.name), WorldClock.defaults.map(\.name))
    }

    func testWatchlistKeepsAtLeastOneSymbol() throws {
        let suite = "DeskPulseTests.settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        for symbol in settings.watchlist.map(\.symbol) { settings.removeSymbol(symbol) }
        XCTAssertEqual(settings.watchlist.count, 1)
        XCTAssertEqual(settings.featuredSymbol, settings.watchlist.first?.symbol)
    }
}
