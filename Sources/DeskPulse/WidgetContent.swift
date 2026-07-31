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
        case .stocks: StocksDashboardView()
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
        }
    }
}

private struct StocksDashboardView: View {
    @EnvironmentObject private var model: DashboardModel
    @StateObject private var quoteModel = AMDQuoteModel()

    var body: some View {
        Group {
            if let quote = quoteModel.quote {
                AMDQuoteContent(
                    quote: quote,
                    chart: quoteModel.chart,
                    isUpdating: quoteModel.isUpdating
                )
            } else {
                LoadingState(label: "Connecting to Nasdaq…")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.open(
                URL(string: "https://www.nasdaq.com/market-activity/stocks/amd/real-time")!
            )
        }
        .task { await quoteModel.poll() }
        .help("Open AMD on Nasdaq")
    }
}

@MainActor
private final class AMDQuoteModel: ObservableObject {
    @Published var quote: AMDQuoteSnapshot?
    @Published var chart: AMDSessionChart?
    @Published var isUpdating = false

    func poll() async {
        while !Task.isCancelled {
            isUpdating = true
            async let newQuote = DataService.fetchAMDQuote()
            async let newChart = DataService.fetchAMDSessionChart()
            let (latest, latestChart) = await (newQuote, newChart)
            if let latest {
                quote = latest
            }
            if let latestChart {
                chart = latestChart
            }
            isUpdating = false
            try? await Task.sleep(for: .seconds(10))
        }
    }
}

private struct AMDQuoteContent: View {
    let quote: AMDQuoteSnapshot
    let chart: AMDSessionChart?
    let isUpdating: Bool

    private var positive: Bool { quote.change >= 0 }
    private var accent: Color { positive ? .green : .red }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 10) {
                identity
                Spacer(minLength: 2)
                price
            }
            if let chart {
                AMDSessionGraph(
                    chart: chart,
                    currentPrice: quote.price,
                    extendedSession: DataService.tradingSession(at: Date())
                )
                    .frame(maxHeight: .infinity)
                chartFooter(chart)
            } else {
                details
                    .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background {
            RadialGradient(
                colors: [accent.opacity(0.12), .clear],
                center: .bottomLeading,
                startRadius: 8,
                endRadius: 280
            )
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Text("AMD")
                    .font(.system(size: 18, weight: .black, design: .rounded))
                Circle()
                    .fill(quote.isExtendedHours ? Color.orange : Color.green)
                    .frame(width: 7, height: 7)
            }
            Text("NASDAQ · \(quote.marketStatus.uppercased())")
                .font(.system(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
        }
    }

    private var price: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(quote.price, format: .currency(code: "USD").precision(.fractionLength(2)))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(String(
                format: "%+.2f  (%+.2f%%)",
                quote.change,
                quote.changePercent
            ))
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(accent)
        }
    }

    private func chartFooter(_ chart: AMDSessionChart) -> some View {
        HStack(spacing: 8) {
            Text("PREV CLOSE \(chart.previousClose, format: .currency(code: "USD").precision(.fractionLength(2)))")
            Spacer()
            if quote.isExtendedHours {
                HStack(spacing: 4) {
                    Circle().fill(.orange).frame(width: 4, height: 4)
                    Text(quote.marketStatus.uppercased())
                }
            }
            Text(chart.timeAsOf)
                .lineLimit(1)
        }
        .font(.system(size: 7.5, weight: .bold, design: .rounded))
        .foregroundStyle(.tertiary)
        .monospacedDigit()
    }

    private var details: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 7) {
                Circle()
                    .fill(quote.isRealTime ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(quote.isRealTime ? "NASDAQ REAL TIME" : "QUOTE")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.7)
                if isUpdating {
                    ProgressView().controlSize(.mini).scaleEffect(0.55)
                }
            }
            .foregroundStyle(.secondary)
            if let bid = quote.bid, let ask = quote.ask {
                Text("BID \(bid, specifier: "%.2f")  ·  ASK \(ask, specifier: "%.2f")")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(quote.tradeTime)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

private struct AMDSessionGraph: View {
    let chart: AMDSessionChart
    let currentPrice: Double
    let extendedSession: AMDTradingSession

    var body: some View {
        Canvas { context, size in
            let displayedPoints = visiblePoints
            guard displayedPoints.count > 1,
                  let firstTime = displayedPoints.first?.timestamp.timeIntervalSince1970,
                  let lastTime = displayedPoints.last?.timestamp.timeIntervalSince1970
            else { return }

            let prices = displayedPoints.map(\.price) + [chart.previousClose, currentPrice]
            guard let rawMinimum = prices.min(), let rawMaximum = prices.max() else { return }
            let rawRange = max(rawMaximum - rawMinimum, 0.5)
            let minimum = rawMinimum - rawRange * 0.08
            let maximum = rawMaximum + rawRange * 0.08
            let timeRange = max(lastTime - firstTime, 1)

            func point(for item: AMDChartPoint) -> CGPoint {
                CGPoint(
                    x: size.width * (item.timestamp.timeIntervalSince1970 - firstTime) / timeRange,
                    y: size.height * (1 - (item.price - minimum) / (maximum - minimum))
                )
            }
            func yPosition(_ price: Double) -> CGFloat {
                size.height * (1 - (price - minimum) / (maximum - minimum))
            }

            var baseline = Path()
            let baselineY = yPosition(chart.previousClose)
            baseline.move(to: CGPoint(x: 0, y: baselineY))
            baseline.addLine(to: CGPoint(x: size.width, y: baselineY))
            context.stroke(
                baseline,
                with: .color(.secondary.opacity(0.52)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 4])
            )

            if let marketOpen = displayedPoints.first(where: { $0.session == .regular }) {
                let openX = point(for: marketOpen).x
                var sessionDivider = Path()
                sessionDivider.move(to: CGPoint(x: openX, y: 0))
                sessionDivider.addLine(to: CGPoint(x: openX, y: size.height))
                context.stroke(
                    sessionDivider,
                    with: .color(.secondary.opacity(0.42)),
                    style: StrokeStyle(lineWidth: 1, dash: [2, 4])
                )
            }

            for index in 1..<displayedPoints.count {
                let previous = displayedPoints[index - 1]
                let current = displayedPoints[index]
                let previousPoint = point(for: previous)
                let currentPoint = point(for: current)
                let previousIsAbove = previous.price >= chart.previousClose
                let currentIsAbove = current.price >= chart.previousClose

                if previousIsAbove == currentIsAbove {
                    stroke(
                        from: previousPoint,
                        to: currentPoint,
                        color: previousIsAbove ? .green : .red,
                        in: &context
                    )
                } else {
                    let fraction = (chart.previousClose - previous.price)
                        / (current.price - previous.price)
                    let crossing = CGPoint(
                        x: previousPoint.x + (currentPoint.x - previousPoint.x) * fraction,
                        y: baselineY
                    )
                    stroke(
                        from: previousPoint,
                        to: crossing,
                        color: previousIsAbove ? .green : .red,
                        in: &context
                    )
                    stroke(
                        from: crossing,
                        to: currentPoint,
                        color: currentIsAbove ? .green : .red,
                        in: &context
                    )
                }
            }

            if let last = displayedPoints.last {
                let finalPoint = point(for: last)
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: finalPoint.x - 2.5, y: finalPoint.y - 2.5,
                        width: 5, height: 5
                    )),
                    with: .color(last.price >= chart.previousClose ? .green : .red)
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AMD current trading session chart")
        .accessibilityValue(
            "Current price \(currentPrice), previous close \(chart.previousClose)"
        )
    }

    private var visiblePoints: [AMDChartPoint] {
        switch extendedSession {
        case .premarket:
            return chart.points.filter { $0.session == .premarket }
        case .afterHours:
            return chart.points
        case .regular:
            return chart.points.filter { $0.session != .afterHours }
        }
    }

    private func stroke(
        from start: CGPoint,
        to end: CGPoint,
        color: Color,
        in context: inout GraphicsContext
    ) {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
        )
    }
}

private struct ClocksWidget: View {
    private let clocks: [(String, String, String)] = [
        ("Austin", "America/Chicago", "🇺🇸"),
        ("Israel", "Asia/Jerusalem", "🇮🇱"),
        ("China", "Asia/Shanghai", "🇨🇳"),
        ("India", "Asia/Kolkata", "🇮🇳")
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            GeometryReader { proxy in
                let timeSize = min(
                    29,
                    max(17, min(proxy.size.width / 34, proxy.size.height / 4.6))
                )
                HStack(spacing: 0) {
                    ForEach(Array(clocks.enumerated()), id: \.element.0) { index, clock in
                        VStack(spacing: 6) {
                            Text(clock.2)
                                .font(.system(size: 17))
                                .accessibilityLabel("\(clock.0) country flag")
                            Text(time(context.date, zone: clock.1))
                                .font(.system(
                                    size: timeSize,
                                    weight: .medium,
                                    design: .rounded
                                ))
                                .monospacedDigit()
                                .minimumScaleFactor(0.72)
                                .lineLimit(1)
                            Text(clock.0)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(localDate(context.date, zone: clock.1))
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone)
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func localDate(_ date: Date, zone: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone)
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: date)
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

private struct StocksWidget: View {
    @EnvironmentObject private var model: DashboardModel

    var body: some View {
        if model.quotes.isEmpty {
            LoadingState(label: "Loading market data…")
        } else {
            VStack(spacing: 0) {
                ForEach(model.quotes) { quote in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(quote.symbol)
                                .font(.system(size: quote.symbol == "AMD" ? 16 : 13, weight: .bold, design: .rounded))
                            if quote.symbol == "AMD" {
                                Text("Advanced Micro Devices")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 105, alignment: .leading)
                        Sparkline(points: quote.points, positive: quote.changePercent >= 0)
                            .frame(maxWidth: .infinity, minHeight: 24)
                        Text(quote.price, format: .number.precision(.fractionLength(2)))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 70, alignment: .trailing)
                        Text(quote.changePercent / 100, format: .percent.precision(.fractionLength(2)))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(quote.changePercent >= 0 ? .green : .red)
                            .frame(width: 62, alignment: .trailing)
                    }
                    .padding(.horizontal, 14)
                    .frame(maxHeight: .infinity)
                    if quote.id != model.quotes.last?.id { Divider().opacity(0.16) }
                }
            }
        }
    }
}

private struct Sparkline: View {
    let points: [Double]
    let positive: Bool

    var body: some View {
        Canvas { context, size in
            guard points.count > 1, let low = points.min(), let high = points.max() else { return }
            let range = Swift.max(high - low, 0.001)
            var path = Path()
            for (index, point) in points.enumerated() {
                let x = size.width * Double(index) / Double(points.count - 1)
                let y = size.height - (point - low) / range * size.height
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(positive ? .green : .red), lineWidth: 1.5)
        }
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
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Feels \(weather.feelsLike)°", systemImage: "thermometer.medium")
                        Label("\(weather.humidity)%", systemImage: "humidity.fill")
                        Label("\(weather.windMPH) mph", systemImage: "wind")
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
                                Text(forecastDay(day.date))
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
            LoadingState(label: "Loading Austin weather…")
        }
    }

    private func forecastDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Chicago")
        formatter.dateFormat = "EEE"
        return formatter.string(from: date).uppercased()
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: source.isRTL ? "he_IL" : "en_US_POSIX")
        formatter.timeZone = TimeZone(
            identifier: source.isRTL ? "Asia/Jerusalem" : "America/Chicago"
        )
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
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

private struct LoadingState: View {
    let label: String
    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
