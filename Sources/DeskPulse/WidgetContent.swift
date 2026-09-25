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
        case .liveTV11: LiveTVWidget(channel: "11", label: "Channel 11")
        case .liveTV: LiveTVWidget(channel: "12", label: "Channel 12")
        case .liveTV13: LiveTVWidget(channel: "13", label: "Channel 13")
        case .liveTVCNN: LiveTVWidget(channel: "cnn", label: "CNN")
        case .radio: RadioWidget()
        case .myNews: MyNewsWidget()
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
        } else {
            LoadingState(label: "Loading \(model.settings.weatherLocation.name) weather…")
        }
    }

    private func forecastDay(_ date: Date, timeZone: String) -> String {
        CachedDateFormatter.string(from: date, format: "EEE", timeZone: timeZone)
            .uppercased()
    }

    private func weatherSymbol(_ code: Int) -> String {
        switch code {
        case 0: "sun.max.fill"
        case 1...3: "cloud.sun.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...82: "cloud.rain.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }
}

private struct FeedWidget: View {
    enum Source {
        case ynet, rotter, cnn, fox

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
        if items.isEmpty {
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

private struct LiveTVWidget: View {
    let channel: String
    let label: String
    @State private var playerSource: LiveTVPlayerSource?

    var body: some View {
        Group {
            if let playerSource {
                switch playerSource {
                case .web(let url):
                    EmbeddedWebView(
                        source: .url(url),
                        allowedHosts: ["mako.co.il"],
                        pageZoom: 1
                    )
                case .hls(let url):
                    EmbeddedWebView(
                        source: .html(Self.hlsPlayerHTML(url: url)),
                        allowedHosts: [],
                        pageZoom: 1
                    )
                }
            } else {
                LoadingState(label: "Locating \(label) player…")
            }
        }
        .id(channel)
        .task {
            playerSource = await DataService.fetchLiveTVPlayerSource(channel: channel)
        }
    }

    private static func hlsPlayerHTML(url: URL) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta name="color-scheme" content="dark">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <style>
            * { box-sizing: border-box; }
            html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: #000; }
            video { display: block; width: 100%; height: 100%; object-fit: contain; background: #000; }
          </style>
        </head>
        <body>
          <video src="\(url.absoluteString)" controls autoplay muted playsinline></video>
          <script>
            const video = document.querySelector('video');
            video.muted = true;
            video.defaultMuted = true;
            video.play().catch(() => {});
          </script>
        </body>
        </html>
        """
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
