import Foundation
import OSLog

/// A Home Front Command alert as pushed by the Red Alert (tzevaadom.co.il) service.
struct RedAlert: Equatable, Sendable {
    let id: String
    let threat: Int
    let cities: [String]
    let isDrill: Bool

    /// Threat codes used by the service; anything else is shown as a general alert.
    var title: String {
        switch threat {
        case 0: "Rocket alert · צבע אדום"
        case 5: "Hostile aircraft intrusion · חדירת כלי טיס עוין"
        default: "Home Front Command alert"
        }
    }

    /// Parses one WebSocket message. Only `ALERT` messages that aren't drills count.
    static func parse(_ message: Data) -> RedAlert? {
        guard
            let root = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
            (root["type"] as? String)?.uppercased() == "ALERT",
            let data = root["data"] as? [String: Any],
            let cities = data["cities"] as? [String],
            !cities.isEmpty
        else { return nil }
        let isDrill = data["isDrill"] as? Bool ?? false
        guard !isDrill else { return nil }
        let id = (data["notificationId"] as? String)
            ?? (data["notificationId"] as? Int).map(String.init)
            ?? UUID().uuidString
        return RedAlert(id: id, threat: data["threat"] as? Int ?? 0, cities: cities, isDrill: false)
    }

    /// With no filters every alert counts; otherwise one of its areas must contain a filter.
    func matches(areas filters: [String]) -> Bool {
        let filters = filters
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !filters.isEmpty else { return true }
        return cities.contains { city in
            filters.contains { city.localizedCaseInsensitiveContains($0) }
        }
    }
}

/// Keeps a WebSocket open to the Red Alert service so alerts arrive the moment they are
/// issued, reconnecting with back-off when the connection drops.
@MainActor
final class RedAlertMonitor: ObservableObject {
    enum Status: Equatable {
        case off
        case connecting
        case connected
        case disconnected(String)
    }

    @Published private(set) var status: Status = .off
    var onAlert: (RedAlert) -> Void = { _ in }

    private static let socketURL = URL(string: "wss://ws.tzevaadom.co.il/socket?platform=WEB")!
    private static let logger = Logger(subsystem: "com.giladfride.DeskPulse", category: "RedAlert")
    private let session = URLSession(configuration: .default)
    private var connection: Task<Void, Never>?
    private var recentIDs: [String] = []

    func start() {
        guard connection == nil else { return }
        connection = Task { [weak self] in await self?.maintainConnection() }
    }

    func stop() {
        connection?.cancel()
        connection = nil
        status = .off
    }

    private func maintainConnection() async {
        var failures = 0
        while !Task.isCancelled {
            status = .connecting
            var request = URLRequest(url: Self.socketURL)
            request.setValue("https://www.tzevaadom.co.il", forHTTPHeaderField: "Origin")
            let socket = session.webSocketTask(with: request)
            socket.resume()
            let keepAlive = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(25))
                    sendKeepAlivePing(socket)
                }
            }
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    failures = 0
                    status = .connected
                    handle(message)
                }
            } catch {
                if !Task.isCancelled {
                    Self.logger.error("Red Alert connection lost: \(error.localizedDescription, privacy: .public)")
                    status = .disconnected(error.localizedDescription)
                }
            }
            keepAlive.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            guard !Task.isCancelled else { break }
            // 2, 4, 8 … up to 60 seconds between attempts.
            failures += 1
            try? await Task.sleep(for: .seconds(min(60, 1 << min(failures, 6))))
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let payload): data = payload
        @unknown default: return
        }
        guard let alert = RedAlert.parse(data), !recentIDs.contains(alert.id) else { return }
        // The service can repeat a notification; remember the last few.
        recentIDs.append(alert.id)
        if recentIDs.count > 50 { recentIDs.removeFirst() }
        Self.logger.info("Red Alert: \(alert.cities.count) areas, threat \(alert.threat)")
        onAlert(alert)
    }
}

/// Sends a WebSocket ping. URLSession calls the pong handler on its own queue, so the
/// handler is explicitly `@Sendable` and created outside any actor-isolated type: a
/// handler Swift infers as main-actor isolated is checked at runtime and trapped on the
/// first ping (even from a `nonisolated` method of the `@MainActor` monitor).
func sendKeepAlivePing(_ socket: URLSessionWebSocketTask) {
    socket.sendPing { @Sendable _ in }
}
