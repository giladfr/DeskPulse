import AppKit
import Foundation
import Network
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
/// issued, reconnecting with back-off when the connection drops, when pings go
/// unanswered, and right after the Mac wakes or its network changes.
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
    private let events = RedAlertSocketEvents()
    private lazy var session = URLSession(configuration: .default, delegate: events, delegateQueue: nil)
    private var connection: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var recentIDs: [String] = []
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var lastPath: NWPath?

    func start() {
        guard connection == nil else { return }
        events.monitor = self
        observeWakeAndNetwork()
        connection = Task { [weak self] in await self?.maintainConnection() }
    }

    func stop() {
        connection?.cancel()
        connection = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        status = .off
    }

    /// Drops the current connection and opens a new one now, without back-off.
    func reconnect(because reason: String) {
        guard connection != nil else { return }
        Self.logger.info("Red Alert reconnecting: \(reason, privacy: .public)")
        connection?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        connection = Task { [weak self] in await self?.maintainConnection() }
    }

    /// A connection that was open before sleep, or on another network, is usually dead
    /// without any error yet; reconnecting at once avoids minutes without alerts.
    private func observeWakeAndNetwork() {
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconnect(because: "the Mac woke from sleep") }
            }
        }
        if pathMonitor == nil {
            let monitor = NWPathMonitor()
            // Delivered on the main queue, where this main-actor code can run.
            monitor.pathUpdateHandler = { [weak self] path in
                MainActor.assumeIsolated { self?.networkChanged(to: path) }
            }
            monitor.start(queue: .main)
            pathMonitor = monitor
        }
    }

    private func networkChanged(to path: NWPath) {
        defer { lastPath = path }
        guard let lastPath, path.status == .satisfied else { return }
        let interfaces = path.availableInterfaces.map(\.name)
        if lastPath.status != .satisfied || lastPath.availableInterfaces.map(\.name) != interfaces {
            reconnect(because: "the network changed")
        }
    }

    private func maintainConnection() async {
        var failures = 0
        while !Task.isCancelled {
            status = .connecting
            var request = URLRequest(url: Self.socketURL)
            request.setValue("https://www.tzevaadom.co.il", forHTTPHeaderField: "Origin")
            let socket = session.webSocketTask(with: request)
            self.socket = socket
            socket.resume()
            let pongs = PongTracker()
            let keepAlive = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(25))
                    guard !Task.isCancelled else { break }
                    // A connection can die without an error (a sleeping router, a
                    // dropped NAT mapping). Two unanswered pings, about 50 seconds,
                    // close it so the loop below reconnects.
                    if pongs.unansweredPings >= 2 {
                        pongs.timedOut = true
                        socket.cancel(with: .goingAway, reason: nil)
                        break
                    }
                    sendKeepAlivePing(socket, pongs: pongs)
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
                    let reason = pongs.timedOut
                        ? "The Red Alert service stopped answering"
                        : error.localizedDescription
                    Self.logger.error("Red Alert connection lost: \(reason, privacy: .public)")
                    status = .disconnected(reason)
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

    /// The service sends nothing until there is an alert, so the connection counts as
    /// up once the WebSocket handshake completes rather than on the first message.
    fileprivate func socketDidOpen(_ opened: URLSessionWebSocketTask) {
        guard opened === socket, status == .connecting else { return }
        status = .connected
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
/// handler must not be main-actor isolated or the runtime isolation check traps. Even an
/// explicitly `@Sendable` closure here was compiled as `@MainActor` by the Swift 6.0
/// whole-module (release) build, though not in debug builds, so the handler is a
/// method of a plain nonisolated class rather than a closure.
func sendKeepAlivePing(_ socket: URLSessionWebSocketTask, pongs: PongTracker) {
    pongs.pingSent()
    socket.sendPing(pongReceiveHandler: pongs.pongReceived)
}

/// Counts pings that have had no successful pong yet. Thread-safe: pongs arrive on
/// URLSession's queue.
final class PongTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var unanswered = 0
    private var didTimeOut = false

    var unansweredPings: Int { lock.withLock { unanswered } }

    /// Set when the connection was closed for not answering.
    var timedOut: Bool {
        get { lock.withLock { didTimeOut } }
        set { lock.withLock { didTimeOut = newValue } }
    }

    func pingSent() {
        lock.withLock { unanswered += 1 }
    }

    @Sendable func pongReceived(_ error: (any Error)?) {
        guard error == nil else { return }
        lock.withLock { unanswered = 0 }
    }
}

/// Reports the WebSocket handshake to the monitor. A delegate method rather than a
/// closure for the same reason as `ignorePong`: URLSession calls it on its own queue.
private final class RedAlertSocketEvents: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    weak var monitor: RedAlertMonitor?

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        let monitor = monitor
        Task { @MainActor in monitor?.socketDidOpen(webSocketTask) }
    }
}
