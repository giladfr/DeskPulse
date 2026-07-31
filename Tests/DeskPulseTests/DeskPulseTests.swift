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

    func testDefaultStocksIncludeIntel() {
        XCTAssertTrue(StockSymbol.defaults.contains {
            $0.tradingViewSymbol == "NASDAQ:INTC"
        })
    }

    func testFeedTitlesDecodeDoubleEncodedHebrewPunctuation() {
        XCTAssertEqual(
            DataService.decodeHTMLEntities("בכיר: &amp;#1523;בדיקה&amp;#1524;"),
            "בכיר: ׳בדיקה״"
        )
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

    func testAMDTradingSessionBoundariesUseEasternTime() throws {
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

}
