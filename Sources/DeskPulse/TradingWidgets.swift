import SwiftUI

/// Shows a symbol's chart on the stock card, opening the card if it is hidden.
@MainActor
private func showChart(_ symbol: String, settings: AppSettings, dashboard: DashboardModel) {
    settings.featuredSymbol = symbol
    settings.stockCardShowsChart = true
    if !dashboard.isVisible(.stocks) {
        dashboard.toggleVisibility(.stocks)
    }
}

// MARK: - Market wire

@MainActor
final class MarketWireModel: ObservableObject {
    @Published private(set) var items: [TradingFeeds.WireItem] = []
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var failed = false
    @Published private(set) var isRefreshing = false

    /// Every minute while the card is open.
    func run(watched: @escaping () -> [String]) async {
        while !Task.isCancelled {
            await refresh(watched: watched())
            try? await Task.sleep(for: .seconds(60))
        }
    }

    func refresh(watched: [String]) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        var sources = TradingFeeds.wireSources
        if let yahoo = TradingFeeds.yahooHeadlinesSource(for: watched) { sources.append(yahoo) }
        let batches = await withTaskGroup(of: (TradingFeeds.WireSource, [FeedItem]).self) { group in
            for source in sources {
                group.addTask { (source, await DataService.fetchFeed(source.url)) }
            }
            var batches: [(TradingFeeds.WireSource, [FeedItem])] = []
            for await batch in group { batches.append(batch) }
            // Watchlist headlines first, so their tickers win when a story repeats.
            return batches.sorted { lhs, _ in lhs.0.id == "yahoo-watchlist" }
        }
        let merged = TradingFeeds.mergeWire(batches, watched: watched)
        if !merged.isEmpty {
            items = merged
            lastUpdate = Date()
            failed = false
        } else if items.isEmpty {
            failed = true
        }
    }
}

/// Financial headlines from Bloomberg, CNBC, WSJ, MarketWatch, FT, Seeking Alpha,
/// EE Times and Yahoo (for the watchlist), newest first, with the symbols each one is
/// about. Filters: tech and semis only, or the watchlist only.
struct MarketWireWidget: View {
    enum Filter: String, CaseIterable, Identifiable {
        case tech = "Tech"
        case watchlist = "Watchlist"
        case all = "All"
        var id: String { rawValue }
    }

    @EnvironmentObject private var dashboard: DashboardModel
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = MarketWireModel()
    @AppStorage("marketWire.filter") private var filter = Filter.tech

    private var watched: [String] { settings.watchlist.map(\.symbol) }

    private var shown: [TradingFeeds.WireItem] {
        switch filter {
        case .all: model.items
        case .tech: model.items.filter(\.isTech)
        case .watchlist: model.items.filter { !Set($0.tickers).isDisjoint(with: watched) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.14)
            if model.items.isEmpty, model.failed {
                UnavailableState(message: "Couldn't load market news.", isRetrying: model.isRefreshing) {
                    Task { await model.refresh(watched: watched) }
                }
            } else if model.items.isEmpty {
                LoadingState(label: "Loading market news…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty {
                Text(filter == .watchlist ? "No recent headlines about your watchlist." : "No headlines.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(shown) { row($0, now: context.date) }
                        }
                        .animation(.snappy(duration: 0.4), value: shown.map(\.id))
                    }
                }
            }
        }
        .task {
            let settings = settings
            await model.run { settings.watchlist.map(\.symbol) }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 5) {
            ForEach(Filter.allCases) { option in
                Button { filter = option } label: {
                    Text(option.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            filter == option ? Color.orange.opacity(0.3) : Color.white.opacity(0.06),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 4)
            if let lastUpdate = model.lastUpdate {
                Text(lastUpdate, format: .dateTime.hour().minute())
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .help("Updated every minute")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func row(_ item: TradingFeeds.WireItem, now: Date) -> some View {
        let isWatched = !Set(item.tickers).isDisjoint(with: watched)
        let age = item.date.map { now.timeIntervalSince($0) } ?? .infinity
        return Button {
            if let link = item.link { dashboard.open(link) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(item.date.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(age < 3600 ? .secondary : .tertiary)
                    if age < 600 {
                        Text("NEW")
                            .font(.system(size: 7.5, weight: .black))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 4)
                            .background(Color.orange, in: Capsule())
                    }
                }
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 12, weight: isWatched ? .semibold : .medium))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        Text(item.source.uppercased())
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(.orange.opacity(0.85))
                        ForEach(item.tickers.prefix(4), id: \.self) { ticker in
                            tickerChip(ticker, watched: watched.contains(ticker))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isWatched ? Color.cyan.opacity(0.06) : Color.clear)
            .overlay(alignment: .leading) {
                if isWatched { Rectangle().fill(Color.cyan).frame(width: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Divider().opacity(0.12) }
    }

    private func tickerChip(_ ticker: String, watched: Bool) -> some View {
        Button {
            showChart(ticker, settings: settings, dashboard: dashboard)
        } label: {
            Text(ticker)
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundStyle(watched ? .cyan : .secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.white.opacity(watched ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .help("Show \(ticker)'s chart on the stock card")
    }
}

// MARK: - Finance TV

/// Bloomberg, Yahoo Finance or CNBC live on YouTube, starting muted. The live video
/// changes when a channel restarts its stream, so it is looked up again regularly.
struct FinanceTVWidget: View {
    @AppStorage("financeTV.channel") private var channelID = TradingFeeds.tvChannels[0].id
    @State private var videoID: String?
    @State private var lookedUp = false
    @State private var attempt = 0

    private var channel: TradingFeeds.TVChannel {
        TradingFeeds.tvChannels.first { $0.id == channelID } ?? TradingFeeds.tvChannels[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(TradingFeeds.tvChannels) { option in
                    Button { channelID = option.id } label: {
                        Text(option.name)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                channelID == option.id ? Color.red.opacity(0.35) : Color.white.opacity(0.06),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Group {
                if case .hls(let url) = channel.source {
                    NativeStreamPlayer(url: url, label: channel.name, muted: true)
                        .id(channel.id)
                } else if let videoID {
                    EmbeddedWebView(
                        source: .html(YouTubeLive.playerHTML(videoID: videoID), baseURL: YouTubeLive.origin),
                        allowedHosts: YouTubeLive.allowedHosts,
                        pageZoom: 1
                    )
                    .id(videoID)
                } else if lookedUp {
                    UnavailableState(
                        message: "\(channel.name) isn't streaming live right now. Checking again every 2 minutes.",
                        isRetrying: false
                    ) { attempt += 1 }
                } else {
                    LoadingState(label: "Finding \(channel.name) live…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        }
        .task(id: "\(channelID)|\(attempt)") {
            videoID = nil
            lookedUp = false
            guard case .youTube(let youTubeChannelID) = channel.source else { return }
            while !Task.isCancelled {
                let found = await TradingFeeds.liveVideoID(channelID: youTubeChannelID)
                guard !Task.isCancelled else { return }
                lookedUp = true
                if found != nil, found != videoID { videoID = found }
                // Recheck a live stream every 15 minutes; an offline channel sooner.
                try? await Task.sleep(for: .seconds(videoID == nil ? 120 : 900))
            }
        }
    }
}

/// YouTube's embedded live player, for Finance TV and Israeli channels on YouTube.
enum YouTubeLive {
    /// The player needs to know which site embeds it (it refuses pages without a
    /// referrer, and pages claiming to be youtube.com). Nothing is loaded from this
    /// address; it only becomes the player page's origin.
    static let origin = URL(string: "https://giladfr.github.io/DeskPulse/")

    static func playerHTML(videoID: String, muted: Bool = true) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <style>
            html, body { margin: 0; width: 100%; height: 100%; overflow: hidden; background: #000; }
            iframe { border: 0; width: 100%; height: 100%; display: block; }
          </style>
        </head>
        <body>
          <iframe src="https://www.youtube.com/embed/\(videoID)?autoplay=1&mute=\(muted ? 1 : 0)&playsinline=1&rel=0&origin=https%3A%2F%2Fgiladfr.github.io"
                  referrerpolicy="strict-origin-when-cross-origin"
                  allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe>
        </body>
        </html>
        """
    }

    static let allowedHosts: Set<String> = ["youtube.com", "youtube-nocookie.com", "google.com", "gstatic.com", "ytimg.com", "googlevideo.com"]
}

// MARK: - Semiconductor heatmap

@MainActor
final class HeatmapModel: ObservableObject {
    @Published private(set) var quotes: [String: MarketQuote] = [:]
    @Published private(set) var failed = false

    /// The shown category's symbols every 30 seconds; quotes from other categories
    /// stay, so switching back shows numbers at once.
    func run(symbols: [String]) async {
        while !Task.isCancelled {
            let result = await MarketData.fetchQuotes(symbols.map { WatchedSymbol(symbol: $0) })
            quotes.merge(result.quotes, uniquingKeysWith: { _, new in new })
            failed = symbols.allSatisfy { quotes[$0] == nil }
            try? await Task.sleep(for: .seconds(30))
        }
    }
}

/// A sector at a glance: semis, hyperscalers, software, cybersecurity, AI
/// infrastructure, the Mag 7, Israeli tech or the watchlist, each stock coloured by
/// its move, with the sector's benchmarks and a count of risers and fallers. Before
/// the open the colour is the pre-market move.
struct HeatmapWidget: View {
    @EnvironmentObject private var dashboard: DashboardModel
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = HeatmapModel()
    @AppStorage("heatmap.category") private var categoryID = TradingFeeds.overviewCategoryID

    private var isOverview: Bool { categoryID == TradingFeeds.overviewCategoryID }

    private var category: TradingFeeds.HeatmapCategory {
        if isOverview {
            // Every name a block might show on a large card, so all have prices.
            let sectors = TradingFeeds.overviewSectorIDs.compactMap { id in
                TradingFeeds.heatmapCategories.first { $0.id == id }
            }
            var seen = Set<String>()
            return .init(
                id: TradingFeeds.overviewCategoryID,
                name: "Tech overview",
                symbols: sectors.flatMap(\.symbols).filter { seen.insert($0).inserted },
                benchmarks: sectors.flatMap(\.benchmarks)
            )
        }
        if categoryID == TradingFeeds.watchlistCategoryID {
            return .init(
                id: TradingFeeds.watchlistCategoryID,
                name: "Watchlist",
                symbols: settings.watchlist.map(\.symbol),
                benchmarks: []
            )
        }
        return TradingFeeds.heatmapCategories.first { $0.id == categoryID } ?? TradingFeeds.heatmapCategories[0]
    }

    var body: some View {
        let category = category
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let premarket = DataService.tradingSession(at: context.date) == .premarket
                && !DataService.isMarketWeekend(context.date)
            VStack(spacing: 6) {
                summary(category, premarket: premarket)
                if category.symbols.allSatisfy({ model.quotes[$0] == nil }) {
                    if model.failed {
                        Text("Couldn't load quotes.").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        LoadingState(label: "Loading \(category.name.lowercased())…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if isOverview {
                    overview(premarket: premarket)
                } else {
                    GeometryReader { proxy in
                        let columns = max(2, Int(proxy.size.width / 78))
                        let rows = max(1, Int(ceil(Double(category.symbols.count) / Double(columns))))
                        // Tiles fill the card, but a short list doesn't make giant ones.
                        let height = min(96, max(34, (proxy.size.height - CGFloat(rows - 1) * 4) / CGFloat(rows)))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
                            ForEach(category.symbols, id: \.self) { symbol in
                                tile(symbol, premarket: premarket, height: height)
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
        .task(id: category.symbols + category.benchmarks) {
            await model.run(symbols: category.benchmarks + category.symbols)
        }
    }

    /// Sector blocks in two balanced columns (one on a narrow card), filling the card:
    /// spare room shows more names per sector rather than bigger tiles.
    private func overview(premarket: Bool) -> some View {
        GeometryReader { proxy in
            let plan = TradingFeeds.overviewPlan(width: proxy.size.width, height: proxy.size.height)
            let columnWidth = plan.columns.count > 1 ? (proxy.size.width - 10) / 2 : proxy.size.width
            ScrollView(.vertical, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(plan.columns.indices, id: \.self) { column in
                        VStack(spacing: 8) {
                            ForEach(plan.columns[column], id: \.category.id) { section in
                                overviewBlock(section, across: plan.across, tileHeight: plan.tileHeight, premarket: premarket)
                            }
                        }
                        .frame(width: columnWidth, alignment: .top)
                    }
                }
            }
        }
    }

    private func overviewBlock(
        _ section: (category: TradingFeeds.HeatmapCategory, symbols: [String]),
        across: Int,
        tileHeight: CGFloat,
        premarket: Bool
    ) -> some View {
        let moves = section.symbols.compactMap { model.quotes[$0] }.map { move($0, premarket: premarket).percent }
        return VStack(spacing: 4) {
            HStack(spacing: 6) {
                Button { categoryID = section.category.id } label: {
                    Text(section.category.name.uppercased())
                        .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show all of \(section.category.name)")
                ForEach(section.category.benchmarks.prefix(1), id: \.self) { symbol in
                    if let quote = model.quotes[symbol] {
                        let value = move(quote, premarket: premarket)
                        Text("\(PriceText.shortName(symbol)) \(PriceText.percent(value.percent))")
                            .foregroundStyle(value.percent >= 0 ? .green : .red)
                    }
                }
                Spacer(minLength: 2)
                if !moves.isEmpty {
                    Text("▲\(moves.filter { $0 > 0 }.count)").foregroundStyle(.green)
                    Text("▼\(moves.filter { $0 < 0 }.count)").foregroundStyle(.red)
                }
            }
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .monospacedDigit()
            .frame(height: 14)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: across), spacing: 4) {
                ForEach(section.symbols, id: \.self) { symbol in
                    tile(symbol, premarket: premarket, height: tileHeight)
                }
            }
        }
    }

    private var categoryMenu: some View {
        Menu {
            Button("Tech overview") { categoryID = TradingFeeds.overviewCategoryID }
            Divider()
            ForEach(TradingFeeds.heatmapCategories) { option in
                Button(option.name) { categoryID = option.id }
            }
            Divider()
            Button("My watchlist") { categoryID = TradingFeeds.watchlistCategoryID }
        } label: {
            HStack(spacing: 3) {
                Text(category.name.uppercased())
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .tracking(0.5)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .heavy))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.08), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose a sector")
    }

    /// The move the tile is coloured by, and what it is.
    private func move(_ quote: MarketQuote, premarket: Bool) -> (percent: Double, label: String?) {
        if premarket, let extended = quote.extendedChangePercent {
            return (extended, "PRE")
        }
        return (quote.dayChangePercent, nil)
    }

    private func summary(_ category: TradingFeeds.HeatmapCategory, premarket: Bool) -> some View {
        let moves = category.symbols.compactMap { model.quotes[$0] }.map { move($0, premarket: premarket).percent }
        let up = moves.filter { $0 > 0 }.count
        let down = moves.filter { $0 < 0 }.count
        return HStack(spacing: 10) {
            categoryMenu
            ForEach(isOverview ? [] : category.benchmarks, id: \.self) { symbol in
                if let quote = model.quotes[symbol] {
                    let value = move(quote, premarket: premarket)
                    HStack(spacing: 4) {
                        Text(PriceText.shortName(symbol)).font(.system(size: 10, weight: .heavy, design: .rounded))
                        Text(PriceText.percent(value.percent))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(value.percent >= 0 ? .green : .red)
                    }
                    .onTapGesture { showChart(symbol, settings: settings, dashboard: dashboard) }
                }
            }
            Spacer(minLength: 4)
            // The overview counts per block instead.
            if !moves.isEmpty, !isOverview {
                Text("▲\(up)").foregroundStyle(.green)
                Text("▼\(down)").foregroundStyle(.red)
            }
            if !moves.isEmpty, premarket {
                Text("PRE-MARKET").foregroundStyle(.orange)
            }
        }
        .font(.system(size: 9.5, weight: .bold, design: .rounded))
        .monospacedDigit()
        .frame(height: 16)
    }

    private func tile(_ symbol: String, premarket: Bool, height: CGFloat) -> some View {
        let quote = model.quotes[symbol]
        let value = quote.map { move($0, premarket: premarket) }
        let percent = value?.percent ?? 0
        // Full colour at ±4%; unchanged is grey.
        let strength = min(abs(percent) / 4, 1)
        let color: Color = abs(percent) < 0.005 ? .gray : percent > 0 ? .green : .red
        // Logo beside the symbol on short tiles, above it on tall ones.
        let logoSize = min(max(height * 0.3, 14), 26)
        let label = Text(symbol)
            .font(.system(size: height > 44 ? 12 : 10.5, weight: .heavy, design: .rounded))
        return VStack(spacing: 2) {
            if height >= 64 {
                CompanyLogo(symbol: symbol, size: logoSize)
                label
            } else {
                HStack(spacing: 4) {
                    CompanyLogo(symbol: symbol, size: logoSize)
                    label
                }
            }
            if let value {
                Text(PriceText.percent(value.percent))
                    .font(.system(size: height > 44 ? 11 : 9.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
            } else {
                Text("…").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(
            quote == nil ? Color.white.opacity(0.04) : color.opacity(0.12 + 0.5 * strength),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { showChart(symbol, settings: settings, dashboard: dashboard) }
        .help(quote.map { "\(symbol): \(PriceText.price($0.price)) · \(PriceText.percent($0.dayChangePercent)) today" + (($0.extendedChangePercent).map { ", \(PriceText.percent($0)) extended" } ?? "") } ?? symbol)
    }
}

// MARK: - Company logos

/// Company logos from Financial Modeling Prep's free image service, downloaded once
/// per symbol, kept in the Caches folder for 30 days, and adapted to dark tiles.
@MainActor
final class LogoStore: ObservableObject {
    static let shared = LogoStore()

    struct Logo {
        let image: NSImage
        /// Dark coloured artwork (ASML navy, TI red) gets a faint light outline.
        let needsOutline: Bool
    }

    @Published private(set) var logos: [String: Logo] = [:]
    private var requested = Set<String>()

    private static let folder: URL? = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("DeskPulse/Logos", isDirectory: true)

    /// The logo if it is ready; otherwise starts loading it and returns nil.
    func logo(for symbol: String) -> Logo? {
        if let logo = logos[symbol] { return logo }
        if requested.insert(symbol).inserted {
            Task { await load(symbol) }
        }
        return nil
    }

    private func load(_ symbol: String) async {
        let file = Self.folder?.appendingPathComponent("\(symbol).png")
        if let file,
           let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < 30 * 86400,
           let image = NSImage(contentsOf: file) {
            logos[symbol] = Self.adaptedForDarkTiles(image) ?? Logo(image: image, needsOutline: false)
            return
        }
        guard
            let escaped = symbol.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
            let url = URL(string: "https://financialmodelingprep.com/image-stock/\(escaped).png"),
            let (data, response) = try? await URLSession.shared.data(from: url),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let image = NSImage(data: data)
        else {
            // Try again next launch rather than every redraw.
            return
        }
        logos[symbol] = Self.adaptedForDarkTiles(image) ?? Logo(image: image, needsOutline: false)
        if let file, let folder = Self.folder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file)
        }
    }

    /// Makes a logo read on a dark tile without a badge: a white box behind the mark
    /// is cut out, a black or grey mark is drawn white, and a dark coloured one is
    /// marked for an outline. Bright marks are left as they are.
    nonisolated static func adaptedForDarkTiles(_ image: NSImage, side: Int = 96) -> Logo? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let data = context.data
        else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        let count = side * side

        func color(_ index: Int) -> (red: Double, green: Double, blue: Double, alpha: Double) {
            let alpha = Double(pixels[index * 4 + 3]) / 255
            guard alpha > 0 else { return (0, 0, 0, 0) }
            return (Double(pixels[index * 4]) / 255 / alpha,
                    Double(pixels[index * 4 + 1]) / 255 / alpha,
                    Double(pixels[index * 4 + 2]) / 255 / alpha,
                    alpha)
        }
        func isNearWhite(_ c: (red: Double, green: Double, blue: Double, alpha: Double)) -> Bool {
            c.alpha > 0.9 && min(c.red, c.green, c.blue) > 0.88
        }

        // A white box: the corners are opaque white. Cut every near-white pixel out,
        // with a soft edge so the mark keeps smooth outlines.
        let corners = [0, side - 1, count - side, count - 1]
        // A coloured square of its own (Arm, KLA) is an icon already; leave it.
        let isColouredSquare = corners.allSatisfy { color($0).alpha > 0.9 && !isNearWhite(color($0)) }
        if corners.allSatisfy({ isNearWhite(color($0)) }) {
            for index in 0..<count {
                let c = color(index)
                guard c.alpha > 0 else { continue }
                let whiteness = min(c.red, c.green, c.blue)
                guard whiteness > 0.75 else { continue }
                // Fully cut at 0.95 and above, kept below 0.75.
                let keep = max(0, min(1, (0.95 - whiteness) / 0.2))
                let alpha = c.alpha * keep
                pixels[index * 4] = UInt8(c.red * alpha * 255)
                pixels[index * 4 + 1] = UInt8(c.green * alpha * 255)
                pixels[index * 4 + 2] = UInt8(c.blue * alpha * 255)
                pixels[index * 4 + 3] = UInt8(alpha * 255)
            }
        }

        // What is left: a dark colourless mark (Intel) would vanish on a dark tile and
        // is drawn white; a dark coloured one keeps its colour with an outline.
        var luminance = 0.0, saturation = 0.0, weight = 0.0
        for index in 0..<count {
            let c = color(index)
            guard c.alpha > 0.1 else { continue }
            let high = max(c.red, c.green, c.blue), low = min(c.red, c.green, c.blue)
            luminance += (0.299 * c.red + 0.587 * c.green + 0.114 * c.blue) * c.alpha
            saturation += (high == 0 ? 0 : (high - low) / high) * c.alpha
            weight += c.alpha
        }
        guard weight > 0 else { return nil }
        let averageLuminance = luminance / weight
        let isColourless = saturation / weight < 0.3
        if !isColouredSquare, averageLuminance < 0.4, isColourless {
            for index in 0..<count {
                let alpha = pixels[index * 4 + 3]
                pixels[index * 4] = alpha
                pixels[index * 4 + 1] = alpha
                pixels[index * 4 + 2] = alpha
            }
        }
        guard let result = context.makeImage() else { return nil }
        return Logo(
            image: NSImage(cgImage: result, size: NSSize(width: side, height: side)),
            needsOutline: !isColouredSquare && !isColourless && averageLuminance < 0.3
        )
    }
}

/// A company's logo, straight on the tile, or its first letter until it arrives.
struct CompanyLogo: View {
    let symbol: String
    var size: CGFloat = 18
    @ObservedObject private var store = LogoStore.shared

    var body: some View {
        Group {
            if let logo = store.logo(for: symbol) {
                Image(nsImage: logo.image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    // Logos that are a coloured square of their own keep soft corners.
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
                    .shadow(color: logo.needsOutline ? .white.opacity(0.9) : .clear, radius: 0.6)
                    .shadow(color: logo.needsOutline ? .white.opacity(0.6) : .black.opacity(0.35), radius: 1.2, y: logo.needsOutline ? 0 : 0.5)
            } else {
                Text(String(symbol.prefix(1)))
                    .font(.system(size: size * 0.6, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Earnings and macro calendar

@MainActor
final class MarketCalendarModel: ObservableObject {
    @Published private(set) var earnings: [TradingFeeds.Earnings] = []
    @Published private(set) var macro: [TradingFeeds.MacroEvent] = []
    @Published private(set) var loadedEarnings = false
    @Published private(set) var loadedMacro = false

    private var allEarnings: [TradingFeeds.Earnings] = []
    private var earningsFetchedAt: Date?

    /// Earnings every 30 minutes, macro (for actuals) every 5.
    func run(watched: @escaping () -> [String]) async {
        while !Task.isCancelled {
            if earningsFetchedAt.map({ Date().timeIntervalSince($0) > 1800 }) ?? true {
                await refreshEarnings()
            }
            earnings = TradingFeeds.relevantEarnings(allEarnings, watched: Set(watched()))
            if let events = await TradingFeeds.fetchMacro() { macro = events }
            loadedMacro = true
            try? await Task.sleep(for: .seconds(300))
        }
    }

    /// Today and the next six days that are weekdays in New York.
    static func reportingDays(from now: Date = Date()) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return (0..<9).compactMap { calendar.date(byAdding: .day, value: $0, to: now) }
            .filter { !calendar.isDateInWeekend($0) }
            .prefix(6)
            .map { formatter.string(from: $0) }
    }

    private func refreshEarnings() async {
        let days = Self.reportingDays()
        let results = await withTaskGroup(of: [TradingFeeds.Earnings]?.self) { group in
            for day in days { group.addTask { await TradingFeeds.fetchEarnings(day: day) } }
            var all: [[TradingFeeds.Earnings]?] = []
            for await result in group { all.append(result) }
            return all
        }
        let fetched = results.compactMap { $0 }
        if !fetched.isEmpty {
            allEarnings = fetched.flatMap { $0 }
            earningsFetchedAt = Date()
        }
        loadedEarnings = true
    }
}

/// This week's earnings for the watchlist, semis and big tech (before the open or
/// after the close), and US economic releases with forecast, previous and actual.
struct MarketCalendarWidget: View {
    enum Tab: String, CaseIterable, Identifiable {
        case earnings = "Earnings"
        case macro = "Macro"
        var id: String { rawValue }
    }

    @EnvironmentObject private var dashboard: DashboardModel
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = MarketCalendarModel()
    @State private var tab = Tab.earnings

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if proxy.size.width >= 600 {
                    HStack(alignment: .top, spacing: 0) {
                        column(title: "EARNINGS") { earningsList(now: context.date) }
                        Divider().opacity(0.14)
                        column(title: "US MACRO") { macroList(now: context.date) }
                    }
                } else {
                    VStack(spacing: 0) {
                        Picker("", selection: $tab) {
                            ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        if tab == .earnings { earningsList(now: context.date) } else { macroList(now: context.date) }
                    }
                }
            }
        }
        .task {
            let settings = settings
            await model.run { settings.watchlist.map(\.symbol) }
        }
    }

    private func column<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 9, weight: .heavy))
                .tracking(1)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Earnings

    @ViewBuilder
    private func earningsList(now: Date) -> some View {
        if model.earnings.isEmpty {
            Text(model.loadedEarnings ? "No reports this week from your watchlist, semis or big tech." : "Loading earnings…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let watched = Set(settings.watchlist.map(\.symbol))
            let days = Dictionary(grouping: model.earnings, by: \.day)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(days.keys.sorted(), id: \.self) { day in
                        Section {
                            ForEach(days[day] ?? []) { report in
                                earningsRow(report, watched: watched.contains(report.symbol))
                            }
                        } header: {
                            dayHeader(dayTitle(day, now: now))
                        }
                    }
                }
            }
        }
    }

    private func earningsRow(_ report: TradingFeeds.Earnings, watched: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: report.time == .beforeOpen ? "sunrise.fill" : report.time == .afterClose ? "moon.stars.fill" : "questionmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(report.time == .beforeOpen ? .orange : report.time == .afterClose ? .indigo : .secondary)
                .frame(width: 14)
                .help(report.time == .beforeOpen ? "Before the open" : report.time == .afterClose ? "After the close" : "Time not announced")
            Text(report.symbol)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(watched ? .cyan : .primary)
                .frame(width: 48, alignment: .leading)
            Text(report.name)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let estimate = report.epsEstimate {
                Text("EPS \(estimate)")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            if let cap = report.marketCap, cap > 0 {
                Text(PriceText.money(cap, symbol: "$", compact: true))
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(watched ? Color.cyan.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { showChart(report.symbol, settings: settings, dashboard: dashboard) }
    }

    // MARK: Macro

    @ViewBuilder
    private func macroList(now: Date) -> some View {
        // Today's releases stay (with their actuals); earlier days drop off.
        let startOfToday = Calendar.current.startOfDay(for: now)
        let events = model.macro.filter { $0.date >= startOfToday }
        if events.isEmpty {
            Text(model.loadedMacro ? "No US releases of note this week." : "Loading economic calendar…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let next = events.first { $0.date > now }
            let days = Dictionary(grouping: events) { Calendar.current.startOfDay(for: $0.date) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(days.keys.sorted(), id: \.self) { day in
                        Section {
                            ForEach(days[day] ?? []) { event in
                                macroRow(event, now: now, isNext: event.id == next?.id)
                            }
                        } header: {
                            dayHeader(dayTitle(day, now: now))
                        }
                    }
                }
            }
        }
    }

    private func macroRow(_ event: TradingFeeds.MacroEvent, now: Date, isNext: Bool) -> some View {
        let past = event.date <= now
        return HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(event.date, format: .dateTime.hour().minute())
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
            Circle()
                .fill(event.impact == .high ? Color.red : Color.orange)
                .frame(width: 6, height: 6)
                .help(event.impact == .high ? "High impact" : "Medium impact")
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 11, weight: isNext ? .bold : .medium))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let actual = event.actual {
                        Text("Actual \(actual)").fontWeight(.heavy).foregroundStyle(.primary)
                    }
                    if let forecast = event.forecast { Text("Fcst \(forecast)") }
                    if let previous = event.previous { Text("Prev \(previous)") }
                }
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if isNext {
                Text("in \(MarketClock.duration(event.date.timeIntervalSince(now)))")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.orange)
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .opacity(past && event.actual == nil ? 0.5 : 1)
        .background(isNext ? Color.orange.opacity(0.08) : Color.clear)
    }

    // MARK: Days

    private func dayHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
    }

    /// "TODAY", "TOMORROW" or "WED OCT 28" for a New York "yyyy-MM-dd".
    private func dayTitle(_ day: String, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyy-MM-dd HH"
        // Noon in New York is the same calendar day here.
        guard let date = formatter.date(from: day + " 12") else { return day }
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)
        let tomorrow = formatter.string(from: now.addingTimeInterval(86400))
        if day == today { return "TODAY" }
        if day == tomorrow { return "TOMORROW" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()
    }

    private func dayTitle(_ day: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(day, inSameDayAs: now) { return "TODAY" }
        if calendar.isDateInTomorrow(day) { return "TOMORROW" }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()
    }
}
