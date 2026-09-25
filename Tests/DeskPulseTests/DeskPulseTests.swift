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
            .ynet, .rotter, .whatsapp, .youtubeMusic, .liveTV, .radio
        ])
        XCTAssertTrue(Set(WidgetKind.allCases).isSuperset(of: kinds))
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

    func testIncomingRocketDetectionMatchesRotterAlertPhrase() {
        XCTAssertTrue(DashboardModel.containsIncomingRocketAlert(
            "דיווח ראשוני: צבע אדום באזור המרכז"
        ))
        XCTAssertTrue(DashboardModel.containsIncomingRocketAlert(
            "התרעה: צבע   אדום בעוטף"
        ))
        XCTAssertFalse(DashboardModel.containsIncomingRocketAlert(
            "עדכון חדשות רגיל ללא התרעה"
        ))
    }

    func testIncomingAlertRuleRecordsOnlyNewMatchingHeadlines() {
        let model = DashboardModel()
        if !model.incomingAlertDetectionEnabled { model.toggleIncomingAlertDetection() }
        let old = FeedItem(title: "צבע אדום בעוטף", link: URL(string: "https://example.com/1"), date: nil)
        let routine = FeedItem(title: "עדכון שגרתי", link: URL(string: "https://example.com/2"), date: nil)

        // The first fetch only sets a baseline, even if it contains an alert.
        model.processIncomingAlertRule([old])
        XCTAssertNil(model.latestIncomingAlert)

        model.processIncomingAlertRule([routine, old])
        XCTAssertNil(model.latestIncomingAlert)

        let fresh = FeedItem(title: "דיווח: צבע אדום באשקלון", link: URL(string: "https://example.com/3"), date: nil)
        model.processIncomingAlertRule([fresh, routine, old])
        XCTAssertEqual(model.latestIncomingAlert?.title, fresh.title)
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

    // MARK: Stocks

    func testSymbolsAreNormalized() {
        XCTAssertEqual(WatchedSymbol.normalized(" nasdaq:amd "), "AMD")
        XCTAssertEqual(WatchedSymbol.normalized("brk.b"), "BRK.B")
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
