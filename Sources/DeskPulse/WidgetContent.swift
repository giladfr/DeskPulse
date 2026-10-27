import SwiftUI

struct WidgetContent: View {
    let kind: WidgetKind

    @ViewBuilder
    var body: some View {
        switch kind {
        case .gmail: EmbeddedWebView(
            source: .url(URL(string: "https://mail.google.com/mail/u/0/#inbox")!),
            allowedHosts: ["google.com", "googleusercontent.com", "gstatic.com"],
            pageZoom: 0.72
        )
        case .stocks: StocksWidget()
        case .clocks: ClocksWidget()
        case .date: DateWidget()
        case .weather: WeatherWidget()
        case .ynet: FeedWidget(source: .ynet)
        case .rotter: FeedWidget(source: .rotter)
        case .cnn: FeedWidget(source: .cnn)
        case .fox: FeedWidget(source: .fox)
        case .redAlert: IsraelRedAlertWidget()
        case .whatsapp: EmbeddedWebView(
            source: .url(URL(string: "https://web.whatsapp.com")!),
            allowedHosts: ["whatsapp.com", "whatsapp.net"],
            pageZoom: 0.72
        )
        case .youtubeMusic: EmbeddedWebView(
            source: .url(URL(string: "https://music.youtube.com")!),
            allowedHosts: ["youtube.com", "google.com", "googleusercontent.com", "gstatic.com"],
            pageZoom: 0.75
        )
        case .liveTV11: LiveTVWidget(channel: LiveTVHubWidget.channels[0])
        case .liveTV: LiveTVWidget(channel: LiveTVHubWidget.channels[1])
        case .liveTV13: LiveTVWidget(channel: LiveTVHubWidget.channels[2])
        case .liveTVCNN: LiveTVWidget(channel: .init(id: "cnn", label: "CNN"))
        case .radio: RadioWidget()
        case .myNews: MyNewsWidget()
        case .marketWire: MarketWireWidget()
        case .financeTV: FinanceTVWidget()
        case .semis: HeatmapWidget()
        case .marketCalendar: MarketCalendarWidget()
        case .liveTVAll: LiveTVHubWidget()
        case .elections: WebTabsWidget(tabs: WebTabsWidget.electionTabs, storageKey: "elections.tab", accent: .blue)
        case .israeliSites: WebTabsWidget(tabs: WebTabsWidget.israeliSiteTabs, storageKey: "israeliSites.tab", accent: .mint)
        }
    }
}

private struct ClocksWidget: View {
    @EnvironmentObject private var settings: AppSettings

    private var clocks: [WorldClock] { settings.clocks }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            GeometryReader { proxy in
                let timeSize = min(
                    29,
                    max(17, min(proxy.size.width / 34, proxy.size.height / 4.6))
                )
                HStack(spacing: 0) {
                    ForEach(Array(clocks.enumerated()), id: \.element.id) { index, clock in
                        VStack(spacing: 6) {
                            Text(clock.flag.isEmpty ? "🕒" : clock.flag)
                                .font(.system(size: 17))
                                .accessibilityHidden(true)
                            Text(time(context.date, zone: clock.timeZone))
                                .font(.system(
                                    size: timeSize,
                                    weight: .medium,
                                    design: .rounded
                                ))
                                .monospacedDigit()
                                .minimumScaleFactor(0.72)
                                .lineLimit(1)
                            Text(clock.name)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(localDate(context.date, zone: clock.timeZone))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if index < clocks.count - 1 {
                            Divider()
                                .frame(height: min(78, proxy.size.height * 0.58))
                                .opacity(0.18)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
    }

    private func time(_ date: Date, zone: String) -> String {
        CachedDateFormatter.string(from: date, format: "HH:mm:ss", timeZone: zone)
    }

    private func localDate(_ date: Date, zone: String) -> String {
        CachedDateFormatter.string(from: date, format: "EEE, MMM d", timeZone: zone)
    }

}

private struct DateWidget: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            GeometryReader { proxy in
                VStack(spacing: 5) {
                    Text(
                        context.date
                            .formatted(.dateTime.weekday(.wide))
                            .uppercased()
                    )
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(.purple)

                    HStack(alignment: .center, spacing: 10) {
                        Text(context.date.formatted(.dateTime.day()))
                            .font(.system(
                                size: min(58, proxy.size.height * 0.42),
                                weight: .light,
                                design: .rounded
                            ))
                            .monospacedDigit()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(context.date.formatted(.dateTime.month(.wide)))
                                .font(.system(
                                    size: min(20, proxy.size.width / 12),
                                    weight: .semibold,
                                    design: .rounded
                                ))
                            Text(context.date.formatted(.dateTime.year()))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 8) {
                        Label(
                            "W\(weekOfYear(context.date))",
                            systemImage: "calendar"
                        )
                        Text("·")
                        Text("DAY \(dayOfYear(context.date))")
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
    }

    private func weekOfYear(_ date: Date) -> Int {
        Calendar.current.component(.weekOfYear, from: date)
    }

    private func dayOfYear(_ date: Date) -> Int {
        Calendar.current.ordinality(of: .day, in: .year, for: date) ?? 1
    }
}

private struct WeatherWidget: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        if let weather = model.weather {
            VStack(spacing: 8) {
                HStack(spacing: 16) {
                    Image(systemName: weatherSymbol(weather.code))
                        .font(.system(size: 38, weight: .light))
                        .symbolRenderingMode(.multicolor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(weather.temperature)°")
                            .font(.system(size: 37, weight: .light, design: .rounded))
                            .monospacedDigit()
                        Text(weather.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(weather.location)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Feels \(weather.feelsLike)°", systemImage: "thermometer.medium")
                        Label("\(weather.humidity)%", systemImage: "humidity.fill")
                        Label("\(weather.wind) \(weather.windUnit)", systemImage: "wind")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)

                if !weather.forecast.isEmpty {
                    Divider().opacity(0.18)
                    HStack(spacing: 0) {
                        ForEach(weather.forecast) { day in
                            VStack(spacing: 3) {
                                Text(forecastDay(day.date, timeZone: weather.timeZone))
                                    .font(.system(size: 8, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                Image(systemName: weatherSymbol(day.code))
                                    .font(.system(size: 16, weight: .medium))
                                    .symbolRenderingMode(.multicolor)
                                HStack(spacing: 3) {
                                    Text("\(day.high)°")
                                        .foregroundStyle(.primary)
                                    Text("\(day.low)°")
                                        .foregroundStyle(.tertiary)
                                }
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        } else if model.failedKinds.contains(.weather) {
            UnavailableState(
                message: "Couldn't load the weather for \(model.settings.weatherLocation.name).",
                isRetrying: model.isRefreshing
            ) { Task { await model.refresh() } }
        } else {
            LoadingState(label: "Loading \(model.settings.weatherLocation.name) weather…")
        }
    }

    private func forecastDay(_ date: Date, timeZone: String) -> String {
        CachedDateFormatter.string(from: date, format: "EEE", timeZone: timeZone)
            .uppercased()
    }

    private func weatherSymbol(_ code: Int) -> String {
        DataService.weatherSymbol(code)
    }
}

private struct FeedWidget: View {
    enum Source {
        case ynet, rotter, cnn, fox

        var kind: WidgetKind {
            switch self {
            case .ynet: .ynet
            case .rotter: .rotter
            case .cnn: .cnn
            case .fox: .fox
            }
        }

        var isRTL: Bool {
            self == .ynet || self == .rotter
        }

        var color: Color {
            switch self {
            case .ynet: .pink
            case .rotter: .yellow
            case .cnn: Color(red: 0.88, green: 0.12, blue: 0.16)
            case .fox: Color(red: 0.20, green: 0.48, blue: 0.95)
            }
        }
    }
    @EnvironmentObject private var model: DashboardModel
    let source: Source

    private var items: [FeedItem] {
        switch source {
        case .ynet: model.ynetItems
        case .rotter: model.rotterItems
        case .cnn: model.cnnItems
        case .fox: model.foxItems
        }
    }

    var body: some View {
        if items.isEmpty, model.failedKinds.contains(source.kind) {
            UnavailableState(
                message: "Couldn't load \(source.kind.title) headlines.",
                isRetrying: model.isRefreshing
            ) { Task { await model.refresh() } }
        } else if items.isEmpty {
            LoadingState(label: "Loading headlines…")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        Button {
                            if let link = item.link { model.open(link) }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                if !source.isRTL {
                                    Circle()
                                        .fill(source.color)
                                        .frame(width: 5, height: 5)
                                        .padding(.top, 6)
                                }
                                VStack(
                                    alignment: source.isRTL ? .trailing : .leading,
                                    spacing: 4
                                ) {
                                    Text(item.title)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .multilineTextAlignment(source.isRTL ? .trailing : .leading)
                                        .lineLimit(3)
                                        .frame(
                                            maxWidth: .infinity,
                                            alignment: source.isRTL ? .trailing : .leading
                                        )
                                    Text(feedTime(item.date))
                                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                        .foregroundStyle(.tertiary)
                                        .monospacedDigit()
                                        .frame(
                                            maxWidth: .infinity,
                                            alignment: source.isRTL ? .trailing : .leading
                                        )
                                }
                                if source.isRTL {
                                    Circle()
                                        .fill(source.color)
                                        .frame(width: 5, height: 5)
                                        .padding(.top, 6)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(
                                maxWidth: .infinity,
                                alignment: source.isRTL ? .trailing : .leading
                            )
                            .contentShape(Rectangle())
                            .environment(\.layoutDirection, .leftToRight)
                        }
                        .buttonStyle(.plain)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .top).combined(with: .opacity),
                                removal: .opacity
                            )
                        )
                        Divider().opacity(0.14)
                    }
                }
                .animation(.snappy(duration: 0.48), value: items.map(\.id))
            }
        }
    }

    private func feedTime(_ date: Date?) -> String {
        guard let date else { return "—:—" }
        return CachedDateFormatter.string(
            from: date,
            format: "HH:mm",
            timeZone: source.isRTL ? "Asia/Jerusalem" : TimeZone.current.identifier,
            locale: source.isRTL ? "he_IL" : "en_US_POSIX"
        )
    }
}

/// Headlines from the sources chosen in Settings, merged newest first, with a chip per
/// source to narrow the list.
private struct MyNewsWidget: View {
    @EnvironmentObject private var model: DashboardModel
    @EnvironmentObject private var settings: AppSettings
    @State private var filter: UUID?

    private var enabledSources: [NewsSource] { settings.newsSources.filter(\.isEnabled) }

    private var items: [NewsItem] {
        guard let filter else { return model.myNewsItems }
        return model.myNewsItems.filter { $0.sourceID == filter }
    }

    var body: some View {
        if enabledSources.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "newspaper").font(.title2).foregroundStyle(.secondary)
                Text("Choose news sources in Settings").font(.caption).foregroundStyle(.secondary)
                SettingsLink { Text("Open Settings…") }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.myNewsItems.isEmpty, model.failedKinds.contains(.myNews) {
            UnavailableState(
                message: "Couldn't load headlines from your news sources.",
                isRetrying: model.isRefreshing
            ) { Task { await model.refresh() } }
        } else if model.myNewsItems.isEmpty {
            LoadingState(label: "Loading headlines…")
        } else {
            VStack(spacing: 0) {
                if enabledSources.count > 1 {
                    sourceChips
                    Divider().opacity(0.14)
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { row($0) }
                    }
                    .animation(.snappy(duration: 0.4), value: items.map(\.id))
                }
            }
        }
    }

    private var sourceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                chip("All", selected: filter == nil) { filter = nil }
                ForEach(enabledSources) { source in
                    chip(source.name, selected: filter == source.id) {
                        filter = filter == source.id ? nil : source.id
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    selected ? Color.teal.opacity(0.3) : Color.white.opacity(0.06),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private func row(_ news: NewsItem) -> some View {
        let rtl = news.item.title.containsRightToLeftText
        return Button {
            if let link = news.item.link { model.open(link) }
        } label: {
            VStack(alignment: rtl ? .trailing : .leading, spacing: 4) {
                Text(news.item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .multilineTextAlignment(rtl ? .trailing : .leading)
                    .lineLimit(3)
                HStack(spacing: 6) {
                    Text(news.sourceName.uppercased())
                        .font(.system(size: 8.5, weight: .heavy))
                        .foregroundStyle(.teal)
                    if let date = news.item.date {
                        Text(date, format: .relative(presentation: .named))
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Divider().opacity(0.14) }
    }
}

extension String {
    /// True when the text contains Hebrew or Arabic letters.
    var containsRightToLeftText: Bool {
        unicodeScalars.contains { (0x0590...0x08FF).contains($0.value) || (0xFB1D...0xFDFF).contains($0.value) }
    }
}

/// A few web pages behind tabs, one shown at a time, with a reload button. Pages that
/// don't update themselves (the election committee's results) reload on a timer.
struct WebTabsWidget: View {
    struct Tab: Identifiable {
        let id: String
        let name: String
        let url: URL
        var zoom: Double = 0.8
        var reloadEverySeconds: Double?
    }

    static let electionTabs: [Tab] = [
        // The Central Elections Committee's official count, as it is entered.
        Tab(id: "results", name: "Official results",
            url: URL(string: "https://votes26.bechirot.gov.il/nationalresults?lang=he")!,
            zoom: 0.75, reloadEverySeconds: 60),
        Tab(id: "map", name: "Results map", url: URL(string: "https://elections.govmap.gov.il/")!, zoom: 0.8),
        Tab(id: "polls", name: "Polls", url: URL(string: "https://www.maariv.co.il/news/elections-2026")!, zoom: 0.7),
        Tab(id: "ynet", name: "ynet live", url: URL(string: "https://www.ynet.co.il/news/elections2026")!, zoom: 0.7)
    ]

    static let israeliSiteTabs: [Tab] = [
        Tab(id: "ynet", name: "ynet", url: URL(string: "https://www.ynet.co.il/")!, zoom: 0.7),
        Tab(id: "n12", name: "N12", url: URL(string: "https://www.mako.co.il/news")!, zoom: 0.7),
        Tab(id: "kan", name: "Kan News", url: URL(string: "https://www.kan.org.il/content/kan-news/")!, zoom: 0.7),
        Tab(id: "haaretz", name: "Haaretz", url: URL(string: "https://www.haaretz.co.il/")!, zoom: 0.7),
        Tab(id: "maariv", name: "Maariv", url: URL(string: "https://www.maariv.co.il/")!, zoom: 0.7),
        Tab(id: "walla", name: "Walla", url: URL(string: "https://www.walla.co.il/")!, zoom: 0.7),
        Tab(id: "i24", name: "i24", url: URL(string: "https://www.i24news.tv/he")!, zoom: 0.7)
    ]

    let tabs: [Tab]
    let accent: Color
    @AppStorage private var selectedID: String
    @State private var reloadCount = 0

    init(tabs: [Tab], storageKey: String, accent: Color) {
        self.tabs = tabs
        self.accent = accent
        _selectedID = AppStorage(wrappedValue: tabs[0].id, storageKey)
    }

    private var selected: Tab { tabs.first { $0.id == selectedID } ?? tabs[0] }

    var body: some View {
        let tab = selected
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(tabs) { option in
                            Button { selectedID = option.id } label: {
                                Text(option.name)
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        option.id == tab.id ? accent.opacity(0.35) : Color.white.opacity(0.06),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let seconds = tab.reloadEverySeconds {
                    Text("updates every \(Int(seconds)) s")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                Button { reloadCount += 1 } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Reload \(tab.name)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            EmbeddedWebView(source: .url(tab.url), allowedHosts: [], pageZoom: tab.zoom, blocksAds: true)
                // A new page per tab and per reload, so each starts clean.
                .id("\(tab.id)|\(reloadCount)")
        }
        .task(id: "\(tab.id)") {
            guard let seconds = tab.reloadEverySeconds else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                reloadCount += 1
            }
        }
    }
}

/// Israeli TV in one card: one channel with sound, or all of them tiled to fit the
/// card, muted until you unmute one in its player.
struct LiveTVHubWidget: View {
    struct Channel {
        let id: String
        let label: String
        /// The broadcaster's official YouTube channel, used when its own stream is
        /// refused (e.g. outside Israel) and the channel is live there.
        var youTube: String?
        /// Only on YouTube.
        var youTubeOnly = false
    }

    static let channels: [Channel] = [
        Channel(id: "11", label: "Kan 11", youTube: "UCKqFqiCe1dCUxRe0_YNZ6gg"),
        Channel(id: "12", label: "Channel 12"),
        Channel(id: "13", label: "Channel 13", youTube: "UC8vRsz-RmoBznazlIULyqhQ"),
        Channel(id: "14", label: "Channel 14"),
        Channel(id: "i24", label: "i24 News", youTube: "UCisowXt5wZkp2sR3rFh9lnQ", youTubeOnly: true)
    ]

    @AppStorage("liveTV.channel") private var channel = "12"
    @AppStorage("liveTV.split") private var split = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(Self.channels, id: \.id) { option in
                    chip(option.label, selected: !split && channel == option.id) {
                        channel = option.id
                        split = false
                    }
                }
                Spacer(minLength: 4)
                chip("All", systemImage: "square.grid.2x2.fill", selected: split) { split = true }
                    .help("Split screen: every channel at once, muted (unmute one in its player)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Group {
                if split {
                    splitScreen
                } else {
                    let selected = Self.channels.first { $0.id == channel } ?? Self.channels[1]
                    // A new identity per channel, so the previous one is torn down.
                    LiveTVWidget(channel: selected, muted: false)
                        .id(selected.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        }
    }

    private var splitScreen: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 4
            let grid = Self.bestGrid(count: Self.channels.count, in: proxy.size, gap: gap)
            let width = (proxy.size.width - CGFloat(grid.columns - 1) * gap) / CGFloat(grid.columns)
            let height = (proxy.size.height - CGFloat(grid.rows - 1) * gap) / CGFloat(grid.rows)
            VStack(spacing: gap) {
                ForEach(0..<grid.rows, id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(0..<grid.columns, id: \.self) { column in
                            let index = row * grid.columns + column
                            if index < Self.channels.count {
                                cell(Self.channels[index])
                                    .frame(width: width, height: height)
                            } else {
                                Color.clear.frame(width: width, height: height)
                            }
                        }
                    }
                }
            }
        }
    }

    private func cell(_ option: Channel) -> some View {
        LiveTVWidget(channel: option, muted: true)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .topLeading) {
                Button {
                    channel = option.id
                    split = false
                } label: {
                    HStack(spacing: 4) {
                        Text(option.label)
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.65), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(5)
                .help("Show \(option.label) alone, with sound")
            }
    }

    /// The rows and columns that make 16:9 pictures as large as possible: four across
    /// on a wide strip, two by two on a squarer card, one column on a tall one.
    static func bestGrid(count: Int, in size: CGSize, gap: CGFloat) -> (columns: Int, rows: Int) {
        var best = (columns: 1, rows: count)
        var bestWidth: CGFloat = 0
        for columns in 1...max(count, 1) {
            let rows = Int((Double(count) / Double(columns)).rounded(.up))
            let cellWidth = (size.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
            let cellHeight = (size.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
            let pictureWidth = min(cellWidth, cellHeight * 16 / 9)
            if pictureWidth > bestWidth + 0.5 {
                bestWidth = pictureWidth
                best = (columns, rows)
            }
        }
        return best
    }

    private func chip(_ title: String, systemImage: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(selected ? Color.blue.opacity(0.4) : Color.white.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct LiveTVWidget: View {
    let channel: LiveTVHubWidget.Channel
    /// Start without sound (several players at once); the player's controls unmute.
    var muted = true
    @State private var playerSource: LiveTVPlayerSource?
    @State private var lookupFailed = false
    @State private var attempt = 0
    /// Playing the broadcaster's YouTube live stream instead of its own.
    @State private var onYouTube = false
    @State private var youTubeVideoID: String?
    @State private var youTubeLookedUp = false

    init(channel: LiveTVHubWidget.Channel, muted: Bool = true) {
        self.channel = channel
        self.muted = muted
        _onYouTube = State(initialValue: channel.youTubeOnly)
    }

    private var label: String { channel.label }

    var body: some View {
        Group {
            if onYouTube {
                if let youTubeVideoID {
                    EmbeddedWebView(
                        source: .html(YouTubeLive.playerHTML(videoID: youTubeVideoID, muted: muted), baseURL: YouTubeLive.origin),
                        allowedHosts: YouTubeLive.allowedHosts,
                        pageZoom: 1
                    )
                    .id(youTubeVideoID)
                } else if youTubeLookedUp {
                    UnavailableState(
                        message: channel.youTubeOnly
                            ? "\(label) isn't live on YouTube right now. Checking again every 2 minutes."
                            : "\(label) isn't available outside Israel and isn't live on YouTube right now. Checking again every 2 minutes.",
                        isRetrying: false
                    ) { retry() }
                } else {
                    LoadingState(label: "Finding \(label) on YouTube…")
                }
            } else if let playerSource {
                switch playerSource {
                case .web(let url):
                    EmbeddedWebView(
                        source: .url(url),
                        allowedHosts: ["mako.co.il", "univtec.com"],
                        pageZoom: 1,
                        startsMuted: muted
                    )
                case .hls(let url):
                    NativeStreamPlayer(url: url, label: label, muted: muted) {
                        if channel.youTube != nil { onYouTube = true }
                    }
                }
            } else if lookupFailed {
                UnavailableState(
                    message: "Couldn't find the \(label) player. Trying again every 30 seconds.",
                    isRetrying: false
                ) { retry() }
            } else {
                LoadingState(label: "Locating \(label) player…")
            }
        }
        .id(channel.id)
        // Retry tapped: start over at once instead of waiting.
        .task(id: "\(channel.id)|\(attempt)|\(onYouTube)") {
            if onYouTube {
                await followYouTube()
                return
            }
            while playerSource == nil, !Task.isCancelled {
                if let source = await DataService.fetchLiveTVPlayerSource(channel: channel.id) {
                    playerSource = source
                    lookupFailed = false
                    return
                }
                if channel.youTube != nil {
                    onYouTube = true
                    return
                }
                lookupFailed = true
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// The broadcaster's live video on YouTube, looked up again regularly: a channel
    /// that goes live (election night) appears, and a restarted stream is followed.
    private func followYouTube() async {
        guard let youTube = channel.youTube else { return }
        while !Task.isCancelled {
            let found = await TradingFeeds.liveVideoID(channelID: youTube)
            guard !Task.isCancelled else { return }
            youTubeLookedUp = true
            if let found, found != youTubeVideoID { youTubeVideoID = found }
            try? await Task.sleep(for: .seconds(youTubeVideoID == nil ? 120 : 900))
        }
    }

    /// Tries the broadcaster's own stream again (or YouTube for YouTube-only channels).
    private func retry() {
        playerSource = nil
        lookupFailed = false
        youTubeVideoID = nil
        youTubeLookedUp = false
        onYouTube = channel.youTubeOnly
        attempt += 1
    }
}

private struct IsraelRedAlertWidget: View {
    private static let compactScript = """
    (() => {
      const applyWidgetLayout = () => {
        if (document.getElementById('deskpulse-alert-style')) return;
        const style = document.createElement('style');
        style.id = 'deskpulse-alert-style';
        style.textContent = `
          html, body, #map { width: 100% !important; height: 100% !important; overflow: hidden !important; }
          #menu {
            top: 0 !important; left: 0 !important; bottom: 0 !important;
            width: min(410px, 68vw) !important; height: 100vh !important;
            border-radius: 0 !important; box-shadow: 5px 0 20px rgba(0,0,0,.45) !important;
          }
          #history { min-height: 270px !important; }
          .leaflet-control-attribution { opacity: .45 !important; }
          @media (max-width: 620px) {
            #menu { width: 100vw !important; max-width: none !important; }
          }
        `;
        document.head.appendChild(style);
        window.dispatchEvent(new Event('resize'));
      };
      applyWidgetLayout();
      setTimeout(applyWidgetLayout, 600);
    })();
    """

    var body: some View {
        EmbeddedWebView(
            source: .url(URL(string: "https://www.tzevaadom.co.il/en/")!),
            allowedHosts: ["tzevaadom.co.il", "google.com", "googleapis.com"],
            pageZoom: 0.78,
            userScript: Self.compactScript
        )
    }
}

/// A card whose data could not be fetched: says so and offers to try again.
struct UnavailableState: View {
    let message: String
    let isRetrying: Bool
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title3)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if isRetrying {
                ProgressView().controlSize(.small)
            } else {
                Button("Retry", action: retry)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LoadingState: View {
    let label: String
    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Date formatters are expensive to create, and the clocks alone formatted several
/// times a second, so each format/zone/locale combination is built once.
@MainActor
enum CachedDateFormatter {
    private static var formatters: [String: DateFormatter] = [:]

    static func string(
        from date: Date,
        format: String,
        timeZone: String,
        locale: String = "en_US_POSIX"
    ) -> String {
        let key = "\(format)|\(timeZone)|\(locale)"
        if let formatter = formatters[key] {
            return formatter.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.timeZone = TimeZone(identifier: timeZone)
        formatter.dateFormat = format
        formatters[key] = formatter
        return formatter.string(from: date)
    }
}
