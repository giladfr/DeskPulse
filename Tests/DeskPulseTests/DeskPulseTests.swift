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
}
