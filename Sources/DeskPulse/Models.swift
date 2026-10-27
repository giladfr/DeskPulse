import Foundation
import SwiftUI

enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case gmail, stocks, clocks, date, weather, ynet, rotter
    case cnn, fox, redAlert
    case whatsapp, youtubeMusic
    case liveTV11, liveTV, liveTV13, liveTVCNN
    case radio
    case myNews
    case marketWire, financeTV, semis, marketCalendar
    /// Israeli TV (Kan 11, Channels 12, 13 and 14) in one card, one at a time or all
    /// at once.
    case liveTVAll
    /// The Knesset election: official live results, the results map, polls, ynet live.
    case elections
    /// Front pages of the main Israeli news sites.
    case israeliSites

    /// Replaced by `liveTVAll`; kept so saved layouts still decode.
    var isRetired: Bool {
        [.liveTV11, .liveTV, .liveTV13].contains(self)
    }

    /// The cards that can be added, in top-bar order.
    static var available: [WidgetKind] {
        allCases.filter { !$0.isRetired }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gmail: "Gmail"
        case .stocks: "Stocks"
        case .clocks: "World clocks"
        case .date: "Today"
        case .weather: "Weather"
        case .ynet: "Ynet"
        case .rotter: "Rotter סקופים"
        case .cnn: "CNN · World"
        case .fox: "Fox News · Latest"
        case .redAlert: "Israel red alert"
        case .whatsapp: "WhatsApp"
        case .youtubeMusic: "YouTube Music"
        case .liveTV11: "Live TV · Channel 11"
        case .liveTV: "Live TV · Channel 12"
        case .liveTV13: "Live TV · Channel 13"
        case .liveTVCNN: "CNN Live"
        case .radio: "Israeli radio"
        case .myNews: "My news"
        case .marketWire: "Market wire"
        case .financeTV: "Finance TV"
        case .semis: "Heatmap"
        case .marketCalendar: "Earnings & macro"
        case .liveTVAll: "Israeli TV"
        case .elections: "Elections 2026"
        case .israeliSites: "Israeli sites"
        }
    }

    var symbol: String {
        switch self {
        case .gmail: "envelope.fill"
        case .stocks: "chart.line.uptrend.xyaxis"
        case .clocks: "clock.fill"
        case .date: "calendar"
        case .weather: "cloud.sun.fill"
        case .ynet: "newspaper.fill"
        case .rotter: "dot.radiowaves.left.and.right"
        case .cnn: "globe.americas.fill"
        case .fox: "bolt.fill"
        case .redAlert: "exclamationmark.triangle.fill"
        case .whatsapp: "message.fill"
        case .youtubeMusic: "music.note"
        case .liveTV11: "11.square.fill"
        case .liveTV: "tv.fill"
        case .liveTV13: "13.square.fill"
        case .liveTVCNN: "globe.americas.fill"
        case .radio: "radio.fill"
        case .myNews: "newspaper.circle.fill"
        case .marketWire: "bolt.horizontal.fill"
        case .financeTV: "play.tv.fill"
        case .semis: "square.grid.3x3.fill"
        case .marketCalendar: "calendar.badge.clock"
        case .liveTVAll: "tv.fill"
        case .elections: "checkmark.seal.fill"
        case .israeliSites: "safari.fill"
        }
    }

    var tint: Color {
        switch self {
        case .gmail: .red
        case .stocks: .green
        case .clocks: .cyan
        case .date: .purple
        case .weather: .orange
        case .ynet: .pink
        case .rotter: .yellow
        case .cnn: Color(red: 0.88, green: 0.12, blue: 0.16)
        case .fox: Color(red: 0.20, green: 0.48, blue: 0.95)
        case .redAlert: Color(red: 1, green: 0.20, blue: 0.16)
        case .whatsapp: Color(red: 0.18, green: 0.82, blue: 0.47)
        case .youtubeMusic: .red
        case .liveTV11: Color(red: 0.25, green: 0.75, blue: 0.95)
        case .liveTV: Color(red: 0.22, green: 0.65, blue: 1)
        case .liveTV13: Color(red: 0.45, green: 0.42, blue: 1)
        case .liveTVCNN: Color(red: 0.90, green: 0.12, blue: 0.15)
        case .radio: Color(red: 0.55, green: 0.42, blue: 1)
        case .myNews: .teal
        case .marketWire: .orange
        case .financeTV: Color(red: 0.95, green: 0.35, blue: 0.25)
        case .semis: Color(red: 0.30, green: 0.85, blue: 0.55)
        case .marketCalendar: .indigo
        case .liveTVAll: Color(red: 0.22, green: 0.65, blue: 1)
        case .elections: Color(red: 0.35, green: 0.55, blue: 1)
        case .israeliSites: .mint
        }
    }
}

enum LiveTVPlayerSource: Equatable {
    case web(URL)
    case hls(URL)
}

struct DashboardWidget: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: WidgetKind
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct DashboardLayoutSnapshot: Codable, Equatable {
    let widgets: [DashboardWidget]
    let hiddenKinds: Set<WidgetKind>
}

enum DashboardLayoutSelection: Equatable {
    case saved(Int)
    case war
}

/// A Red Alert (Home Front Command) alert that passed the user's area filter.
struct IncomingAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let areas: [String]
    let receivedAt: Date
    /// Sent from Settings to check the banner, sound and notification.
    var isTest = false

    /// "Tel Aviv, Ramat Gan +12 more"
    var areaSummary: String {
        let shown = areas.prefix(4).joined(separator: ", ")
        return areas.count > 4 ? "\(shown) +\(areas.count - 4) more" : shown
    }
}

/// A headline from one of the user's news sources.
struct NewsItem: Identifiable, Equatable {
    let item: FeedItem
    let sourceID: UUID
    let sourceName: String

    var id: String { item.id }
}

struct FeedItem: Identifiable, Equatable {
    var id: String { link?.absoluteString ?? title }
    let title: String
    let link: URL?
    let date: Date?
}

struct StockQuote: Equatable {
    let symbol: String
    /// Short company or fund name, e.g. "Advanced Micro Devices".
    let name: String
    let price: Double
    let change: Double
    let changePercent: Double
    let bid: Double?
    let ask: Double?
    let volume: String
    let marketStatus: String
    let tradeTime: String
    let isRealTime: Bool
    let isExtendedHours: Bool
}

enum TradingSession: Equatable {
    case premarket
    case regular
    case afterHours
}

struct StockChartPoint: Identifiable, Equatable {
    var id: TimeInterval { timestamp.timeIntervalSince1970 }
    let timestamp: Date
    let price: Double
    let session: TradingSession
}

struct StockSessionChart: Equatable {
    let points: [StockChartPoint]
    let previousClose: Double
    let timeAsOf: String
}

struct WeatherSnapshot: Equatable {
    let location: String
    let timeZone: String
    let temperature: Int
    let feelsLike: Int
    let description: String
    let humidity: Int
    let wind: Int
    let windUnit: String
    let code: Int
    let forecast: [DailyForecast]
}

struct DailyForecast: Identifiable, Equatable {
    var id: Date { date }
    let date: Date
    let high: Int
    let low: Int
    let code: Int
}
