import AppKit
import Combine
import Darwin
import Foundation
import IOKit.pwr_mgt

@MainActor
final class DashboardModel: ObservableObject {
    @Published var widgets: [DashboardWidget]
    @Published var weather: WeatherSnapshot?
    @Published var ynetItems: [FeedItem] = []
    @Published var rotterItems: [FeedItem] = []
    @Published var cnnItems: [FeedItem] = []
    @Published var foxItems: [FeedItem] = []
    /// Headlines from the sources chosen in Settings, newest first.
    @Published var myNewsItems: [NewsItem] = []
    @Published var lastRefresh: Date?
    @Published var isRefreshing = false
    @Published var needsInitialArrange = false
    @Published private(set) var hiddenKinds: Set<WidgetKind> {
        didSet { refreshIfDataWidgetsAppeared(previouslyHidden: oldValue) }
    }
    @Published private(set) var savedLayoutSlots: Set<Int> = []
    @Published private(set) var snapsToGrid: Bool
    @Published private(set) var preventsSleep = false
    @Published private(set) var activeLayout: DashboardLayoutSelection?
    @Published private(set) var hasSavedWarLayout: Bool
    @Published private(set) var incomingAlertDetectionEnabled: Bool
    @Published private(set) var warActivationRequest = 0
    /// The most recent alert the rule caught, shown on screens other than the dashboard.
    @Published private(set) var latestIncomingAlert: IncomingAlert?

    private let storageKey = "dashboard.widgets.v2"
    private let hiddenStorageKey = "dashboard.hidden-widgets.v1"
    private let layoutStoragePrefix = "dashboard.saved-layout.v1."
    private let snapToGridStorageKey = "dashboard.snap-to-grid.v1"
    private let activeLayoutStorageKey = "dashboard.active-layout.v1"
    private let warLayoutStorageKey = "dashboard.war-layout.v1"
    private let incomingAlertDetectionStorageKey =
        "dashboard.incoming-alert-detection.v1"
    private let compactAMDStorageKey = "dashboard.compact-amd-widget.v1"
    private let compactRowSizeStorageKey = "dashboard.compact-row-size.v3"
    private var refreshTask: Task<Void, Never>?
    private var sleepAssertionID = IOPMAssertionID(0)
    /// Real-time Red Alert connection, open while incoming-alert detection is on.
    let redAlert = RedAlertMonitor()
    private var refreshRequestedAgain = false
    private var settingsObservation: AnyCancellable?
    let settings: AppSettings

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        let defaults = UserDefaults.standard
        incomingAlertDetectionEnabled = defaults.object(
            forKey: incomingAlertDetectionStorageKey
        ) as? Bool ?? true
        hasSavedWarLayout = defaults.data(forKey: warLayoutStorageKey) != nil
        let storedActiveLayout = defaults.integer(forKey: activeLayoutStorageKey)
        if storedActiveLayout == 0,
           defaults.object(forKey: activeLayoutStorageKey) != nil {
            activeLayout = .war
        } else if (1...4).contains(storedActiveLayout) {
            activeLayout = .saved(storedActiveLayout)
        } else {
            activeLayout = nil
        }
        snapsToGrid = defaults.object(forKey: snapToGridStorageKey) as? Bool ?? true
        if let rawValues = defaults.stringArray(forKey: hiddenStorageKey) {
            hiddenKinds = Set(rawValues.compactMap(WidgetKind.init(rawValue:)))
        } else {
            hiddenKinds = []
        }
        let storedWidgets = defaults.data(forKey: storageKey).flatMap {
            try? JSONDecoder().decode([DashboardWidget].self, from: $0)
        }
        widgets = storedWidgets ?? Self.defaultWidgets
        savedLayoutSlots = Set((1...4).filter {
            defaults.data(forKey: "\(layoutStoragePrefix)\($0)") != nil
        })
        if storedWidgets != nil {
            migrateStoredWidgets()
        } else {
            defaults.set(true, forKey: compactAMDStorageKey)
        }
        inferActiveSavedLayoutIfNeeded()
        ensureWidgetLibrary()
        observeSettings()
        redAlert.onAlert = { [weak self] alert in self?.handle(alert) }
    }

    /// Re-fetches weather and news soon after their settings change, instead of
    /// waiting for the next scheduled refresh.
    private func observeSettings() {
        settingsObservation = Publishers.Merge3(
            settings.$weatherLocation.dropFirst().map { _ in () },
            settings.$temperatureUnit.dropFirst().map { _ in () },
            settings.$newsSources.dropFirst().map { _ in () }
        )
        .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
        .sink { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// One-time upgrades for layouts saved by earlier versions.
    private func migrateStoredWidgets() {
        let defaults = UserDefaults.standard
        var changed = false
        for (kind, width, height) in [(WidgetKind.date, 280.0, 145.0), (.radio, 460, 240)]
        where !widgets.contains(where: { $0.kind == kind }) {
            widgets.append(DashboardWidget(
                id: UUID(), kind: kind, x: 16, y: 16,
                width: width, height: height
            ))
            needsInitialArrange = true
            changed = true
        }
        if !defaults.bool(forKey: compactAMDStorageKey),
           let index = widgets.firstIndex(where: { $0.kind == .stocks }) {
            widgets[index].width = min(widgets[index].width, 480)
            widgets[index].height = 190
            defaults.set(true, forKey: compactAMDStorageKey)
            changed = true
        }
        if !defaults.bool(forKey: compactRowSizeStorageKey) {
            let compactIndices = widgets.indices.filter {
                Self.compactTopRowKinds.contains(widgets[$0].kind)
            }
            if let topY = compactIndices.map({ widgets[$0].y }).min() {
                for index in compactIndices {
                    widgets[index].y = topY
                    widgets[index].height = Self.compactWidgetDefaultHeight
                }
                changed = true
            }
            defaults.set(true, forKey: compactRowSizeStorageKey)
        }
        if changed { save() }
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                let minutes = self?.settings.refreshMinutes ?? 2
                try? await Task.sleep(for: .seconds(max(1, minutes) * 60))
                await self?.refresh()
            }
        }
        if incomingAlertDetectionEnabled { redAlert.start() }
        if !settings.priceAlerts.isEmpty || (incomingAlertDetectionEnabled && settings.notifiesIncomingAlerts) {
            Notifier.setUp()
        }
    }

    func refresh() async {
        guard !isRefreshing else {
            // Something changed mid-refresh (e.g. a setting); run once more after.
            refreshRequestedAgain = true
            return
        }
        isRefreshing = true
        // Only fetch what an open widget shows.
        let wantsWeather = isVisible(.weather)
        let wantsYnet = isVisible(.ynet)
        let wantsRotter = isVisible(.rotter)
        let wantsCNN = isVisible(.cnn)
        let wantsFox = isVisible(.fox)
        let newsSources = isVisible(.myNews) ? settings.newsSources.filter(\.isEnabled) : []
        let location = settings.weatherLocation
        let unit = settings.temperatureUnit
        async let newWeather = Self.fetchWeather(at: location, unit: unit, if: wantsWeather)
        async let newMyNews = Self.fetchNews(from: newsSources)
        async let newYnet = Self.fetchFeed(Self.ynetFeedURL, if: wantsYnet)
        async let newRotter = Self.fetchFeed(Self.rotterFeedURL, if: wantsRotter)
        async let newCNN = Self.fetchFeed(Self.cnnFeedURL, if: wantsCNN)
        async let newFox = Self.fetchFeed(Self.foxFeedURL, if: wantsFox)
        let results = await (newWeather, newYnet, newRotter, newCNN, newFox)
        let myNews = await newMyNews
        if !myNews.isEmpty || newsSources.isEmpty { myNewsItems = myNews }
        if let value = results.0 { weather = value }
        if !results.1.isEmpty { ynetItems = results.1 }
        if !results.2.isEmpty { rotterItems = results.2 }
        if !results.3.isEmpty {
            cnnItems = results.3.map {
                FeedItem(
                    title: $0.title.replacingOccurrences(of: " - CNN", with: ""),
                    link: $0.link,
                    date: $0.date
                )
            }
        }
        if !results.4.isEmpty { foxItems = results.4 }
        lastRefresh = Date()
        isRefreshing = false
        if refreshRequestedAgain {
            refreshRequestedAgain = false
            await refresh()
        }
    }

    nonisolated private static let ynetFeedURL = URL(string: "https://www.ynet.co.il/Integration/StoryRss2.xml")!
    nonisolated private static let rotterFeedURL = URL(string: "https://rotter.net/rss/rotternews.xml")!
    nonisolated private static let cnnFeedURL = URL(
        string: "https://news.google.com/rss/search?q=when%3A1d%20source%3ACNN%20world&hl=en-US&gl=US&ceid=US%3Aen"
    )!
    nonisolated private static let foxFeedURL = URL(string: "https://moxie.foxnews.com/google-publisher/latest.xml")!
    private static let dataBackedKinds: Set<WidgetKind> = [.weather, .ynet, .rotter, .cnn, .fox, .myNews]

    nonisolated private static func fetchWeather(
        at location: WeatherLocation,
        unit: TemperatureUnit,
        if enabled: Bool
    ) async -> WeatherSnapshot? {
        enabled ? await DataService.fetchWeather(at: location, unit: unit) : nil
    }

    nonisolated private static func fetchNews(from sources: [NewsSource]) async -> [NewsItem] {
        guard !sources.isEmpty else { return [] }
        let batches = await withTaskGroup(of: (NewsSource, [FeedItem]).self) { group in
            for source in sources {
                group.addTask { (source, await DataService.fetchFeed(source.url)) }
            }
            var batches: [(NewsSource, [FeedItem])] = []
            for await batch in group { batches.append(batch) }
            return batches
        }
        return mergeNews(batches)
    }

    /// Interleaves several feeds newest first (undated items last), without
    /// duplicates, keeping the most recent 80.
    nonisolated static func mergeNews(_ batches: [(NewsSource, [FeedItem])]) -> [NewsItem] {
        var seen = Set<String>()
        let items = batches.flatMap { source, items in
            items.map { NewsItem(item: $0, sourceID: source.id, sourceName: source.name) }
        }
        .filter { seen.insert($0.id).inserted }
        return items
            .sorted { lhs, rhs in
                switch (lhs.item.date, rhs.item.date) {
                case let (left?, right?): left > right
                case (.some, nil): true
                case (nil, .some): false
                case (nil, nil): lhs.sourceName < rhs.sourceName
                }
            }
            .prefix(80)
            .map { $0 }
    }

    nonisolated private static func fetchFeed(_ url: URL, if enabled: Bool) async -> [FeedItem] {
        enabled ? await DataService.fetchFeed(url) : []
    }

    /// Hidden widgets are not refreshed, so fetch right away when one reappears
    /// instead of showing stale data until the next scheduled refresh.
    private func refreshIfDataWidgetsAppeared(previouslyHidden: Set<WidgetKind>) {
        guard
            refreshTask != nil,
            !previouslyHidden.subtracting(hiddenKinds).isDisjoint(with: Self.dataBackedKinds)
        else { return }
        Task { await refresh() }
    }

    /// Locks immediately, like Control–Command–Q. `SACLockScreenImmediate` is a private
    /// symbol in login.framework: it isn't App Store–safe and may disappear in a macOS
    /// update, in which case this falls back to sleeping the display (which locks when
    /// "Require password after screen saver begins or display is turned off" is set).
    func lockScreen() {
        let frameworkPath = "/System/Library/PrivateFrameworks/login.framework/login"
        if let handle = dlopen(frameworkPath, RTLD_LAZY),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            typealias LockScreenFunction = @convention(c) () -> Void
            let lock = unsafeBitCast(symbol, to: LockScreenFunction.self)
            lock()
            dlclose(handle)
            return
        }

        let fallback = Process()
        fallback.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        fallback.arguments = ["displaysleepnow"]
        try? fallback.run()
    }

    func toggleSleepPrevention() {
        if preventsSleep {
            if sleepAssertionID != 0 {
                IOPMAssertionRelease(sleepAssertionID)
                sleepAssertionID = 0
            }
            preventsSleep = false
            return
        }

        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "DeskPulse is keeping this display awake" as CFString,
            &assertionID
        )
        if result == kIOReturnSuccess {
            sleepAssertionID = assertionID
            preventsSleep = true
        }
    }

    func toggleIncomingAlertDetection() {
        incomingAlertDetectionEnabled.toggle()
        UserDefaults.standard.set(
            incomingAlertDetectionEnabled,
            forKey: incomingAlertDetectionStorageKey
        )
        if incomingAlertDetectionEnabled {
            redAlert.start()
        } else {
            redAlert.stop()
        }
    }

    /// Checks the whole alert path (banner, sound, notification) without a real alert.
    /// The situation layout is left alone.
    func sendTestAlert() {
        deliver(IncomingAlert(
            title: "Test alert · צבע אדום",
            areas: ["תל אביב - יפו", "רמת גן"],
            receivedAt: Date(),
            isTest: true
        ))
    }

    func update(_ widget: DashboardWidget) {
        guard let index = widgets.firstIndex(where: { $0.id == widget.id }) else { return }
        widgets[index] = widget
        save()
    }

    func add(_ kind: WidgetKind) {
        if widgets.contains(where: { $0.kind == kind }), hiddenKinds.contains(kind) {
            hiddenKinds.remove(kind)
            saveHiddenKinds()
            return
        }
        let offset = Double((widgets.count % 5) * 28)
        let defaultWidth = kind == .clocks ? 460.0 : 360.0
        let defaultHeight = Self.compactTopRowKinds.contains(kind)
            ? Self.compactWidgetDefaultHeight
            : 300.0
        widgets.append(DashboardWidget(
            id: UUID(), kind: kind, x: 40 + offset, y: 80 + offset,
            width: defaultWidth, height: defaultHeight
        ))
        save()
    }

    func remove(_ id: UUID) {
        guard let kind = widgets.first(where: { $0.id == id })?.kind else { return }
        hiddenKinds.insert(kind)
        saveHiddenKinds()
    }

    var visibleWidgets: [DashboardWidget] {
        widgets.filter { !hiddenKinds.contains($0.kind) }
    }

    func isVisible(_ kind: WidgetKind) -> Bool {
        widgets.contains(where: { $0.kind == kind }) && !hiddenKinds.contains(kind)
    }

    func toggleVisibility(_ kind: WidgetKind) {
        if isVisible(kind) {
            hiddenKinds.insert(kind)
        } else if widgets.contains(where: { $0.kind == kind }) {
            hiddenKinds.remove(kind)
        } else {
            add(kind)
            return
        }
        saveHiddenKinds()
    }

    func toggleSnapToGrid() {
        snapsToGrid.toggle()
        UserDefaults.standard.set(snapsToGrid, forKey: snapToGridStorageKey)
    }

    func saveLayout(slot: Int) {
        guard (1...4).contains(slot) else { return }
        let snapshot = DashboardLayoutSnapshot(
            widgets: widgets,
            hiddenKinds: hiddenKinds
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: "\(layoutStoragePrefix)\(slot)")
        savedLayoutSlots.insert(slot)
        setActiveLayout(.saved(slot))
    }

    @discardableResult
    func restoreLayout(slot: Int) -> Bool {
        guard
            (1...4).contains(slot),
            let data = UserDefaults.standard.data(
                forKey: "\(layoutStoragePrefix)\(slot)"
            ),
            let snapshot = try? JSONDecoder().decode(
                DashboardLayoutSnapshot.self,
                from: data
            )
        else { return false }

        widgets = snapshot.widgets
        hiddenKinds = snapshot.hiddenKinds
        needsInitialArrange = false
        save()
        saveHiddenKinds()
        setActiveLayout(.saved(slot))
        return true
    }

    func activateWarLayout(in canvasSize: CGSize) {
        if let data = UserDefaults.standard.data(forKey: warLayoutStorageKey),
           let storedSnapshot = try? JSONDecoder().decode(
               DashboardLayoutSnapshot.self,
               from: data
           ) {
            let snapshot = Self.normalizedWarSnapshot(storedSnapshot)
            widgets = snapshot.widgets
            hiddenKinds = snapshot.hiddenKinds
            if snapshot != storedSnapshot,
               let migrated = try? JSONEncoder().encode(snapshot) {
                UserDefaults.standard.set(migrated, forKey: warLayoutStorageKey)
            }
            needsInitialArrange = false
            save()
            saveHiddenKinds()
            setActiveLayout(.war)
            return
        }
        applyDefaultWarLayout(in: canvasSize)
    }

    func saveWarLayout() {
        let snapshot = DashboardLayoutSnapshot(
            widgets: widgets,
            hiddenKinds: hiddenKinds
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: warLayoutStorageKey)
        hasSavedWarLayout = true
        setActiveLayout(.war)
    }

    private func applyDefaultWarLayout(in canvasSize: CGSize) {
        guard canvasSize.width > 900, canvasSize.height > 600 else { return }
        let edge = 16.0
        let gap = 16.0
        let width = Double(canvasSize.width)
        let height = Double(canvasSize.height)
        let topHeight = min(Self.compactWidgetDefaultHeight, max(150, height * 0.14))
        let dateWidth = min(330, max(250, width * 0.16))
        let clocksWidth = width - edge * 2 - gap - dateWidth
        let mediaY = edge + topHeight + gap
        let mediaWidth = (width - edge * 2 - gap * 3) / 4
        let mediaHeight = min(260, max(190, mediaWidth * 9 / 16))
        let mainY = mediaY + mediaHeight + gap
        let mainHeight = max(320, height - mainY - edge)
        let alertWidth = min(500, max(380, width * 0.24))
        let whatsappWidth = min(650, max(480, width * 0.30))
        let whatsappX = edge + alertWidth + gap
        let newsX = whatsappX + whatsappWidth + gap
        let newsAreaWidth = width - newsX - edge
        let newsWidth = (newsAreaWidth - gap) / 2
        let newsHeight = (mainHeight - gap) / 2

        let frames: [(WidgetKind, CGRect)] = [
            (.clocks, CGRect(x: edge, y: edge, width: clocksWidth, height: topHeight)),
            (.date, CGRect(x: edge + clocksWidth + gap, y: edge, width: dateWidth, height: topHeight)),
            (.liveTV11, CGRect(x: edge, y: mediaY, width: mediaWidth, height: mediaHeight)),
            (.liveTV, CGRect(x: edge + mediaWidth + gap, y: mediaY, width: mediaWidth, height: mediaHeight)),
            (.liveTVCNN, CGRect(x: edge + (mediaWidth + gap) * 2, y: mediaY, width: mediaWidth, height: mediaHeight)),
            (.radio, CGRect(x: edge + (mediaWidth + gap) * 3, y: mediaY, width: mediaWidth, height: mediaHeight)),
            (.redAlert, CGRect(x: edge, y: mainY, width: alertWidth, height: mainHeight)),
            (.whatsapp, CGRect(x: whatsappX, y: mainY, width: whatsappWidth, height: mainHeight)),
            (.ynet, CGRect(x: newsX, y: mainY, width: newsWidth, height: newsHeight)),
            (.rotter, CGRect(x: newsX + newsWidth + gap, y: mainY, width: newsWidth, height: newsHeight)),
            (.cnn, CGRect(x: newsX, y: mainY + newsHeight + gap, width: newsWidth, height: newsHeight)),
            (.fox, CGRect(x: newsX + newsWidth + gap, y: mainY + newsHeight + gap, width: newsWidth, height: newsHeight))
        ]

        for (kind, frame) in frames {
            if let index = widgets.firstIndex(where: { $0.kind == kind }) {
                widgets[index].x = frame.minX
                widgets[index].y = frame.minY
                widgets[index].width = frame.width
                widgets[index].height = frame.height
            } else {
                widgets.append(DashboardWidget(
                    id: UUID(),
                    kind: kind,
                    x: frame.minX,
                    y: frame.minY,
                    width: frame.width,
                    height: frame.height
                ))
            }
        }

        let warKinds = Set(frames.map(\.0))
        hiddenKinds = Set(WidgetKind.allCases).subtracting(warKinds)
        needsInitialArrange = false
        save()
        saveHiddenKinds()
        setActiveLayout(.war)
    }

    func autoArrange(in canvasSize: CGSize) {
        guard canvasSize.width > 500, canvasSize.height > 500 else { return }
        widgets = Self.tidiedLayout(
            widgets,
            hiddenKinds: hiddenKinds,
            canvasSize: canvasSize
        )
        needsInitialArrange = false
        save()
    }

    static func tidiedLayout(
        _ source: [DashboardWidget],
        hiddenKinds: Set<WidgetKind>,
        canvasSize: CGSize
    ) -> [DashboardWidget] {
        let grid = 16.0
        let gap = grid
        let edge = grid
        let rightEdge = Double(canvasSize.width) - edge
        let bottomEdge = Double(canvasSize.height) - edge
        func snap(_ value: Double) -> Double {
            (value / grid).rounded() * grid
        }

        var result = source
        let visible = result.indices.filter {
            !hiddenKinds.contains(result[$0].kind)
        }
        guard !visible.isEmpty else { return result }

        // First normalize every frame to the same grid.
        for index in visible {
            result[index].x = max(edge, snap(result[index].x))
            result[index].y = max(edge, snap(result[index].y))
            result[index].width = max(224, snap(result[index].width))
            result[index].height = max(160, snap(result[index].height))
        }

        func rowGroups() -> [[Int]] {
            var groups: [[Int]] = []
            for index in visible.sorted(by: { result[$0].y < result[$1].y }) {
                if let groupIndex = groups.firstIndex(where: {
                    guard let first = $0.first else { return false }
                    return abs(result[first].y - result[index].y) <= grid
                }) {
                    groups[groupIndex].append(index)
                } else {
                    groups.append([index])
                }
            }
            return groups
        }

        func tidyRows() {
            for group in rowGroups() where group.count > 1 {
                let ordered = group.sorted { result[$0].x < result[$1].x }
                let commonY = ordered.map { result[$0].y }.sorted()[ordered.count / 2]
                let heights = ordered.map { result[$0].height }.sorted()
                let shouldEqualizeHeight =
                    heights.last! - heights.first! <= grid * 4
                    || ordered.allSatisfy {
                        compactTopRowKinds.contains(result[$0].kind)
                    }

                for index in ordered {
                    result[index].y = commonY
                    if shouldEqualizeHeight {
                        result[index].height = heights[heights.count / 2]
                    }
                }

                if let first = ordered.first, result[first].x <= edge + grid {
                    result[first].x = edge
                }
                for position in 1..<ordered.count {
                    let previous = ordered[position - 1]
                    let current = ordered[position]
                    let existingGap = result[current].x
                        - (result[previous].x + result[previous].width)
                    if existingGap >= -grid && existingGap <= grid * 4 {
                        result[current].x =
                            result[previous].x + result[previous].width + gap
                    }
                }
                if let last = ordered.last {
                    let existingRight = result[last].x + result[last].width
                    if abs(existingRight - rightEdge) <= grid * 4 {
                        result[last].width = max(224, rightEdge - result[last].x)
                    }
                }
            }
        }

        tidyRows()

        // Align widgets that are already visually stacked into columns.
        let byTop = visible.sorted { result[$0].y < result[$1].y }
        for lower in byTop {
            let candidates = byTop.filter { upper in
                guard result[upper].y < result[lower].y else { return false }
                let upperBottom = result[upper].y + result[upper].height
                let verticalGap = result[lower].y - upperBottom
                let leftDifference = abs(result[upper].x - result[lower].x)
                let widthDifference = abs(result[upper].width - result[lower].width)
                return verticalGap >= -grid
                    && verticalGap <= grid * 4
                    && leftDifference <= grid * 4
                    && widthDifference <= grid * 6
            }
            guard let upper = candidates.max(by: {
                result[$0].y < result[$1].y
            }) else { continue }
            result[lower].x = result[upper].x
            result[lower].width = result[upper].width
            result[lower].y = result[upper].y + result[upper].height + gap
        }

        // A column alignment can create a cleaner shared row; normalize it once more.
        tidyRows()

        // Use the final grid cell at the bottom instead of leaving a narrow dead strip.
        for index in visible {
            let bottom = result[index].y + result[index].height
            if abs(bottom - bottomEdge) <= grid * 3 {
                result[index].height = max(160, bottomEdge - result[index].y)
            }
            result[index].width = min(
                result[index].width,
                rightEdge - result[index].x
            )
            result[index].height = min(
                result[index].height,
                bottomEdge - result[index].y
            )
        }
        return result
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(widgets) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func saveHiddenKinds() {
        UserDefaults.standard.set(
            hiddenKinds.map(\.rawValue).sorted(),
            forKey: hiddenStorageKey
        )
    }

    private func ensureWidgetLibrary() {
        let additions: [(WidgetKind, Double, Double)] = [
            (.redAlert, 500, 500),
            (.liveTV11, 520, 300),
            (.liveTV13, 520, 300),
            (.liveTVCNN, 520, 300),
            (.cnn, 420, 400),
            (.fox, 420, 400),
            (.myNews, 460, 420)
        ]
        var changed = false
        for (kind, width, height) in additions
        where !widgets.contains(where: { $0.kind == kind }) {
            widgets.append(DashboardWidget(
                id: UUID(),
                kind: kind,
                x: 32,
                y: 32,
                width: width,
                height: height
            ))
            hiddenKinds.insert(kind)
            changed = true
        }
        if changed {
            save()
            saveHiddenKinds()
        }
    }

    private func inferActiveSavedLayoutIfNeeded() {
        guard activeLayout == nil else { return }
        for slot in 1...4 {
            guard
                let data = UserDefaults.standard.data(
                    forKey: "\(layoutStoragePrefix)\(slot)"
                ),
                let snapshot = try? JSONDecoder().decode(
                    DashboardLayoutSnapshot.self,
                    from: data
                ),
                snapshot.widgets == widgets,
                snapshot.hiddenKinds == hiddenKinds
            else { continue }
            setActiveLayout(.saved(slot))
            return
        }
    }

    /// Upgrades a situation layout saved before CNN Live replaced Channel 13 there.
    static func normalizedWarSnapshot(
        _ snapshot: DashboardLayoutSnapshot
    ) -> DashboardLayoutSnapshot {
        var migratedWidgets = snapshot.widgets
        if !migratedWidgets.contains(where: { $0.kind == .liveTVCNN }),
           let channel13Index = migratedWidgets.firstIndex(
               where: { $0.kind == .liveTV13 }
           ) {
            migratedWidgets[channel13Index].kind = .liveTVCNN
        }
        var migratedHiddenKinds = snapshot.hiddenKinds
        migratedHiddenKinds.insert(.liveTV13)
        migratedHiddenKinds.remove(.liveTVCNN)
        return DashboardLayoutSnapshot(
            widgets: migratedWidgets,
            hiddenKinds: migratedHiddenKinds
        )
    }

    private func setActiveLayout(_ selection: DashboardLayoutSelection) {
        activeLayout = selection
        switch selection {
        case .saved(let slot):
            UserDefaults.standard.set(slot, forKey: activeLayoutStorageKey)
        case .war:
            UserDefaults.standard.set(0, forKey: activeLayoutStorageKey)
        }
    }

    /// A real alert from Red Alert: shown everywhere and switches to the situation
    /// layout, if it concerns one of the areas chosen in Settings.
    func handle(_ alert: RedAlert) {
        guard incomingAlertDetectionEnabled, alert.matches(areas: settings.alertAreas) else { return }
        deliver(IncomingAlert(title: alert.title, areas: alert.cities, receivedAt: Date()))
        if activeLayout != .war {
            warActivationRequest &+= 1
        }
    }

    /// Recorded even when the situation layout is already up, so other screens (such
    /// as the HDMI screen in its own Space) still hear about new alerts.
    private func deliver(_ alert: IncomingAlert) {
        latestIncomingAlert = alert
        guard settings.notifiesIncomingAlerts else { return }
        Notifier.post(
            id: "incoming-alert-\(alert.id.uuidString)",
            title: alert.title,
            body: alert.areaSummary
        )
    }

    static let defaultWidgets: [DashboardWidget] = [
        .init(id: UUID(), kind: .clocks, x: 24, y: 16, width: 530, height: compactWidgetDefaultHeight),
        .init(id: UUID(), kind: .date, x: 570, y: 16, width: 250, height: compactWidgetDefaultHeight),
        .init(id: UUID(), kind: .weather, x: 836, y: 16, width: 330, height: compactWidgetDefaultHeight),
        .init(id: UUID(), kind: .stocks, x: 1182, y: 16, width: 814, height: compactWidgetDefaultHeight),
        .init(id: UUID(), kind: .gmail, x: 24, y: 222, width: 876, height: 500),
        .init(id: UUID(), kind: .ynet, x: 916, y: 392, width: 530, height: 330),
        .init(id: UUID(), kind: .rotter, x: 1462, y: 392, width: 534, height: 330),
        .init(id: UUID(), kind: .whatsapp, x: 24, y: 738, width: 960, height: 390),
        .init(id: UUID(), kind: .youtubeMusic, x: 1000, y: 738, width: 996, height: 390),
        .init(id: UUID(), kind: .liveTV, x: 24, y: 1144, width: 960, height: 480),
        .init(id: UUID(), kind: .radio, x: 1000, y: 1144, width: 520, height: 260)
    ]

    static let compactTopRowKinds: Set<WidgetKind> = [.clocks, .date, .weather, .stocks]
    static let compactWidgetDefaultHeight = 170.0
}
