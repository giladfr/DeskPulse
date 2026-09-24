import Foundation
import SwiftUI

enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case gmail, stocks, clocks, date, weather, ynet, rotter
    case cnn, fox, redAlert
    case whatsapp, youtubeMusic
    case liveTV11, liveTV, liveTV13, liveTVCNN
    case radio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gmail: "Gmail"
        case .stocks: "AMD live"
        case .clocks: "World clocks"
        case .date: "Today"
        case .weather: "Austin weather"
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

struct FeedItem: Identifiable, Equatable {
    var id: String { link?.absoluteString ?? title }
    let title: String
    let link: URL?
    let date: Date?
}

struct AMDQuoteSnapshot: Equatable {
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

enum AMDTradingSession: Equatable {
    case premarket
    case regular
    case afterHours
}

struct AMDChartPoint: Identifiable, Equatable {
    var id: TimeInterval { timestamp.timeIntervalSince1970 }
    let timestamp: Date
    let price: Double
    let session: AMDTradingSession
}

struct AMDSessionChart: Equatable {
    let points: [AMDChartPoint]
    let previousClose: Double
    let timeAsOf: String
}

struct WeatherSnapshot: Equatable {
    let temperature: Int
    let feelsLike: Int
    let description: String
    let humidity: Int
    let windMPH: Int
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
