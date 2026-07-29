import Foundation
import SwiftUI

enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case gmail, stocks, clocks, date, weather, ynet, rotter, whatsapp, youtubeMusic, liveTV, radio

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
        case .whatsapp: "WhatsApp"
        case .youtubeMusic: "YouTube Music"
        case .liveTV: "Live TV · Channel 12"
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
        case .whatsapp: "message.fill"
        case .youtubeMusic: "music.note"
        case .liveTV: "tv.fill"
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
        case .whatsapp: Color(red: 0.18, green: 0.82, blue: 0.47)
        case .youtubeMusic: .red
        case .liveTV: Color(red: 0.22, green: 0.65, blue: 1)
        case .radio: Color(red: 0.55, green: 0.42, blue: 1)
        }
    }
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

struct FeedItem: Identifiable, Equatable {
    var id: String { link?.absoluteString ?? title }
    let title: String
    let link: URL?
    let date: Date?
}

struct Quote: Identifiable, Equatable {
    var id: String { symbol }
    let symbol: String
    let price: Double
    let changePercent: Double
    let points: [Double]
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

struct StockSymbol: Codable, Identifiable, Equatable {
    var id: String { tradingViewSymbol }
    let tradingViewSymbol: String
    let label: String

    static let defaults: [StockSymbol] = [
        .init(tradingViewSymbol: "NASDAQ:AMD", label: "AMD"),
        .init(tradingViewSymbol: "NASDAQ:NVDA", label: "NVDA"),
        .init(tradingViewSymbol: "NASDAQ:AVGO", label: "AVGO"),
        .init(tradingViewSymbol: "NYSE:TSM", label: "TSM"),
        .init(tradingViewSymbol: "NASDAQ:INTC", label: "INTC"),
        .init(tradingViewSymbol: "NASDAQ:SOXX", label: "SOXX")
    ]
}
