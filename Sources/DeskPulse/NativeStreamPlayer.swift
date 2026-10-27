@preconcurrency import AVFoundation
import AVKit
import Combine
import SwiftUI

/// Plays an HLS live stream with AVPlayer rather than a web page: Apple's player keeps
/// sound in sync over AirPlay (whose 2-second delay web players handle badly), can
/// send the stream to an AirPlay speaker directly, and uses less of the Mac. It
/// reconnects when the stream stalls or fails, and stops completely when removed.
@MainActor
final class StreamPlayerModel: ObservableObject {
    @Published private(set) var message: String?
    /// Called once when the stream has failed three times in a row.
    var onGiveUp: (() -> Void)?

    let player = AVPlayer()
    private var url: URL?
    private var label = ""
    private var failures = 0
    private var observations = Set<AnyCancellable>()
    private var retryTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?

    init() {
        // The player for each channel keeps a few seconds in hand, which AirPlay needs.
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = true
        player.preventsDisplaySleepDuringVideoPlayback = false
    }

    func start(url: URL, label: String, muted: Bool) {
        self.url = url
        self.label = label
        player.isMuted = muted
        load()
        startWatchdog()
    }

    func stop() {
        retryTask?.cancel()
        watchdog?.cancel()
        observations.removeAll()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func load() {
        guard let url else { return }
        observations.removeAll()
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 8
        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    failures = 0
                    message = nil
                case .failed:
                    failed()
                default:
                    break
                }
            }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
            .merge(with: NotificationCenter.default.publisher(for: AVPlayerItem.playbackStalledNotification, object: item))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleReload(after: 4) }
            .store(in: &observations)
        player.replaceCurrentItem(with: item)
        player.play()
    }

    private func failed() {
        failures += 1
        if failures == 3 { onGiveUp?() }
        message = failures >= 3
            ? "\(label) isn't playing. The stream may be limited to viewers in its country. Retrying every 30 seconds."
            : "Reconnecting to \(label)…"
        scheduleReload(after: failures >= 3 ? 30 : 4)
    }

    private func scheduleReload(after seconds: Double) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.load()
        }
    }

    /// A live stream whose clock stops moving for 20 seconds while it should be
    /// playing is reloaded.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            var lastTime = -1.0
            var stuckSince = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                let time = player.currentTime().seconds
                if player.rate == 0 && player.timeControlStatus == .paused {
                    stuckSince = Date()
                } else if time != lastTime {
                    lastTime = time
                    stuckSince = Date()
                } else if Date().timeIntervalSince(stuckSince) > 20 {
                    stuckSince = Date()
                    message = "Reconnecting to \(label)…"
                    load()
                }
            }
        }
    }
}

/// A live HLS stream with the system's player controls and an AirPlay button.
struct NativeStreamPlayer: View {
    let url: URL
    let label: String
    var muted = true
    /// Called when the stream keeps failing, e.g. to switch to another source.
    var onGiveUp: (() -> Void)?
    @StateObject private var model = StreamPlayerModel()

    var body: some View {
        PlayerViewRepresentable(player: model.player)
            .overlay {
                if let message = model.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.75))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                RoutePickerRepresentable(player: model.player)
                    .frame(width: 28, height: 28)
                    .background(Color.black.opacity(0.45), in: Circle())
                    .padding(6)
                    .help("Play on an AirPlay speaker or TV (the device streams it directly)")
            }
            .background(Color.black)
            .onAppear {
                model.onGiveUp = onGiveUp
                model.start(url: url, label: label, muted: muted)
            }
            .onDisappear { model.stop() }
    }
}

private struct PlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

private struct RoutePickerRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        view.player = player
    }
}
