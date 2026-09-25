import AppKit
import AVFoundation
@preconcurrency import MediaPlayer
import SwiftUI

struct RadioStation: Identifiable, Equatable {
    let id: String
    let frequency: String
    let name: String
    let subtitle: String
    let streamURL: URL
    let color: Color

    static let all: [RadioStation] = [
        .init(
            id: "galgalatz", frequency: "91.8", name: "גלגלצ",
            subtitle: "GALGALATZ",
            streamURL: URL(string: "https://glzicylv01.bynetcdn.com/glglz_mp3")!,
            color: .cyan
        ),
        .init(
            id: "galatz", frequency: "96.6", name: "גל״צ",
            subtitle: "GALATZ",
            streamURL: URL(string: "https://glzicylv01.bynetcdn.com/glz_mp3")!,
            color: .orange
        ),
        .init(
            id: "eco99", frequency: "99", name: "אקו 99",
            subtitle: "ECO99FM",
            streamURL: URL(string: "https://eco01.livecdn.biz/ecolive/99fm_aac/icecast.audio")!,
            color: .green
        ),
        .init(
            id: "radius100", frequency: "100", name: "רדיוס",
            subtitle: "RADIUS",
            streamURL: URL(string: "https://cdn.cybercdn.live/Radios_100FM_Website/Audio/icecast.audio")!,
            color: .pink
        ),
        .init(
            id: "telaviv102", frequency: "102", name: "רדיו תל אביב",
            subtitle: "TEL AVIV",
            streamURL: URL(string: "https://cdn88.mediacast.co.il/102-tlv-live/102fm_aac/icecast.audio")!,
            color: .red
        )
    ]

    /// The stations shown on the card: built-ins that aren't hidden, then the user's own.
    static func stations(hiding hidden: Set<String>, adding custom: [CustomRadioStation]) -> [RadioStation] {
        let stations = all.filter { !hidden.contains($0.id) } + custom.map {
            RadioStation(
                id: "custom-\($0.id.uuidString)",
                frequency: "★",
                name: $0.name,
                subtitle: String($0.name.uppercased().prefix(12)),
                streamURL: $0.streamURL,
                color: .teal
            )
        }
        return stations.isEmpty ? all : stations
    }
}

private final class RadioMetadataReceiver: NSObject, AVPlayerItemMetadataOutputPushDelegate,
    @unchecked Sendable
{
    var onMetadata: (([AVMetadataItem]) -> Void)?

    func metadataOutput(
        _ output: AVPlayerItemMetadataOutput,
        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
        from track: AVPlayerItemTrack?
    ) {
        onMetadata?(groups.flatMap(\.items))
    }
}

private final class MediaCommandRegistration: @unchecked Sendable {
    let command: MPRemoteCommand
    let target: Any

    init(command: MPRemoteCommand, target: Any) {
        self.command = command
        self.target = target
    }

    func remove() {
        command.removeTarget(target)
    }
}

private struct MusicBrainzSearchResponse: Decodable {
    let releaseGroups: [ReleaseGroup]

    struct ReleaseGroup: Decodable {
        let id: String
    }

    enum CodingKeys: String, CodingKey {
        case releaseGroups = "release-groups"
    }
}

private struct RecognizedTrack: Decodable, Sendable {
    let title: String?
    let artist: String?
    let artworkURL: String?
    let shazamURL: String?
}

/// Lets a `Process` be terminated from a task-cancellation handler.
private final class ProcessHandle: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

private enum ShazamIORecognizer {
    /// GUI apps get a minimal PATH, so check the usual Homebrew and MacPorts
    /// locations for both Apple silicon and Intel Macs before searching PATH.
    static let ffmpegURL: URL? = {
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let directories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
            + pathDirectories
        return directories
            .map { URL(fileURLWithPath: $0).appendingPathComponent("ffmpeg") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    /// Cancelling the calling task terminates both helper processes.
    static func recognize(streamURL: URL) async -> RecognizedTrack? {
        guard !Task.isCancelled, let ffmpegURL else { return nil }
        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("DeskPulse-Shazam-\(UUID().uuidString)")
        let sampleURL = workDirectory.appendingPathComponent("sample.wav")
        defer { try? fileManager.removeItem(at: workDirectory) }

        do {
            try fileManager.createDirectory(
                at: workDirectory,
                withIntermediateDirectories: true
            )

            let ffmpeg = Process()
            ffmpeg.executableURL = ffmpegURL
            ffmpeg.arguments = [
                "-nostdin", "-hide_banner", "-loglevel", "error",
                "-rw_timeout", "15000000",
                "-t", "10", "-i", streamURL.absoluteString,
                "-vn", "-ac", "1", "-ar", "44100",
                "-c:a", "pcm_s16le", "-y", sampleURL.path
            ]
            ffmpeg.standardOutput = FileHandle.nullDevice
            ffmpeg.standardError = FileHandle.nullDevice
            guard
                try await run(ffmpeg) == 0,
                !Task.isCancelled,
                fileManager.fileExists(atPath: sampleURL.path)
            else { return nil }

            let appHelper = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/ShazamRecognizer")
            let developmentHelper = URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("Tools/bin/ShazamRecognizer")
            let helperURL = fileManager.isExecutableFile(atPath: appHelper.path)
                ? appHelper
                : developmentHelper
            guard fileManager.isExecutableFile(atPath: helperURL.path) else { return nil }

            let recognizer = Process()
            let output = Pipe()
            recognizer.executableURL = helperURL
            recognizer.arguments = [sampleURL.path]
            recognizer.standardOutput = output
            recognizer.standardError = FileHandle.nullDevice
            guard try await run(recognizer) == 0, !Task.isCancelled else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let result = try JSONDecoder().decode(RecognizedTrack.self, from: data)
            guard
                let title = result.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                !title.isEmpty
            else { return nil }
            return result
        } catch {
            return nil
        }
    }

    /// Runs a process without blocking a thread and terminates it on cancellation.
    private static func run(_ process: Process) async throws -> Int32 {
        let handle = ProcessHandle(process)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                handle.process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try handle.process.run()
                } catch {
                    handle.process.terminationHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                // Cancellation may have arrived before the process started.
                if Task.isCancelled { handle.terminate() }
            }
        } onCancel: {
            handle.terminate()
        }
    }
}

@MainActor
private final class RadioArtworkFetcher {
    static let shared = RadioArtworkFetcher()

    private let images = NSCache<NSString, NSImage>()
    private var misses = Set<String>()
    private var lastMusicBrainzRequest = Date.distantPast

    func artwork(from url: URL) async -> NSImage? {
        let key = url.absoluteString as NSString
        if let cached = images.object(forKey: key) { return cached }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard
                (response as? HTTPURLResponse)?.statusCode == 200,
                let image = NSImage(data: data)
            else { return nil }
            images.setObject(image, forKey: key)
            return image
        } catch {
            return nil
        }
    }

    func artwork(artist: String, title: String) async -> NSImage? {
        let key = "\(artist.lowercased())|\(title.lowercased())"
        if let cached = images.object(forKey: key as NSString) { return cached }
        if misses.contains(key) { return nil }

        // MusicBrainz asks clients to average no more than one request per second.
        let delay = 1.05 - Date().timeIntervalSince(lastMusicBrainzRequest)
        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }
        guard !Task.isCancelled else { return nil }
        lastMusicBrainzRequest = Date()

        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release-group/")!
        components.queryItems = [
            URLQueryItem(name: "query", value: "releasegroup:\"\(title)\" AND artist:\"\(artist)\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let searchURL = components.url else { return nil }

        do {
            var request = URLRequest(url: searchURL)
            request.setValue(
                "DeskPulse/1.0 (personal macOS dashboard)",
                forHTTPHeaderField: "User-Agent"
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            guard
                (response as? HTTPURLResponse)?.statusCode == 200,
                let releaseGroupID = try JSONDecoder()
                    .decode(MusicBrainzSearchResponse.self, from: data)
                    .releaseGroups.first?.id,
                let coverURL = URL(
                    string: "https://coverartarchive.org/release-group/\(releaseGroupID)/front-250"
                )
            else {
                misses.insert(key)
                return nil
            }

            let (imageData, imageResponse) = try await URLSession.shared.data(from: coverURL)
            guard
                (imageResponse as? HTTPURLResponse)?.statusCode == 200,
                let image = NSImage(data: imageData)
            else {
                misses.insert(key)
                return nil
            }
            images.setObject(image, forKey: key as NSString)
            return image
        } catch {
            if !Task.isCancelled { misses.insert(key) }
            return nil
        }
    }
}

@MainActor
final class RadioPlayerModel: ObservableObject {
    @Published var selectedID: String
    @Published var isPlaying = false {
        didSet {
            updateMediaCommandAvailability()
            publishNowPlaying()
        }
    }
    @Published var volume: Double = 0.75 {
        didSet { player.volume = Float(volume) }
    }
    @Published var nowPlayingTitle: String?
    @Published var nowPlayingArtist: String?
    @Published var artwork: NSImage?
    @Published var isRecognizing = false

    private let player = AVPlayer()
    private let metadataReceiver = RadioMetadataReceiver()
    private var metadataOutput: AVPlayerItemMetadataOutput?
    private var artworkTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var acceptsMediaCommands = false
    private var mediaCommandTargets: [MediaCommandRegistration] = []
    private let selectionKey = "dashboard.radio.station.v1"
    /// Set from Settings by the card; custom stations are only known then.
    private(set) var stations = RadioStation.all
    private var recognizesSongs = true

    init() {
        // A custom station may be saved; keep its ID until the station list arrives.
        selectedID = UserDefaults.standard.string(forKey: selectionKey) ?? RadioStation.all[0].id
        player.volume = Float(volume)
        metadataReceiver.onMetadata = { [weak self] items in
            Task { @MainActor [weak self] in
                self?.consumeMetadata(items)
            }
        }
        installMediaCommands()
    }

    var selectedStation: RadioStation {
        stations.first(where: { $0.id == selectedID }) ?? stations[0]
    }

    func update(stations: [RadioStation], recognizesSongs: Bool) {
        self.stations = stations.isEmpty ? RadioStation.all : stations
        self.recognizesSongs = recognizesSongs
        if !recognizesSongs {
            stopRecognition()
        } else if isPlaying, recognitionTask == nil {
            startRecognition()
        }
        objectWillChange.send()
    }

    func select(_ station: RadioStation) {
        selectedID = station.id
        UserDefaults.standard.set(station.id, forKey: selectionKey)
        prepareToPlay(station)
        player.play()
        isPlaying = true
        startRecognition()
        publishNowPlaying()
    }

    func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            prepareToPlay(selectedStation)
            player.play()
            isPlaying = true
            startRecognition()
        }
    }

    func setMediaCommandsActive(_ active: Bool) {
        acceptsMediaCommands = active
        updateMediaCommandAvailability()
        publishNowPlaying()
    }

    func cycleStation(by offset: Int) {
        guard isPlaying, let current = stations.firstIndex(of: selectedStation) else {
            return
        }
        let count = stations.count
        let next = (current + offset % count + count) % count
        select(stations[next])
    }

    private func prepareToPlay(_ station: RadioStation) {
        artworkTask?.cancel()
        nowPlayingTitle = nil
        nowPlayingArtist = nil
        artwork = nil

        let item = AVPlayerItem(url: station.streamURL)
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        output.setDelegate(metadataReceiver, queue: .main)
        item.add(output)
        metadataOutput = output
        player.replaceCurrentItem(with: item)
    }

    private func stopPlayback() {
        player.pause()
        if let output = metadataOutput, let item = player.currentItem {
            item.remove(output)
        }
        metadataOutput = nil
        player.replaceCurrentItem(with: nil)
        stopRecognition()
        artworkTask?.cancel()
        artworkTask = nil
        isPlaying = false
    }

    private func consumeMetadata(_ items: [AVMetadataItem]) {
        let values = items.compactMap(\.stringValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let raw = values.last else { return }

        let cleaned = raw
            .replacingOccurrences(of: "StreamTitle='", with: "")
            .replacingOccurrences(of: "';", with: "")
        let parts = cleaned.split(separator: "-", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        let artist: String?
        let title: String
        if parts.count == 2 {
            artist = parts[0]
            title = parts[1]
        } else {
            artist = nil
            title = cleaned
        }
        guard title != nowPlayingTitle || artist != nowPlayingArtist else { return }

        nowPlayingArtist = artist
        nowPlayingTitle = title
        artwork = nil
        publishNowPlaying()
        artworkTask?.cancel()
        guard let artist, !artist.isEmpty, !title.isEmpty else { return }
        artworkTask = Task { [weak self] in
            let image = await RadioArtworkFetcher.shared.artwork(artist: artist, title: title)
            guard !Task.isCancelled else { return }
            self?.artwork = image
            self?.publishNowPlaying()
        }
    }

    private func startRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        guard recognizesSongs else { return }
        let streamURL = selectedStation.streamURL
        recognitionTask = Task { [weak self] in
            // Give playback priority while its connection settles.
            try? await Task.sleep(for: .seconds(4))
            while !Task.isCancelled {
                self?.isRecognizing = true
                let match = await ShazamIORecognizer.recognize(streamURL: streamURL)
                guard !Task.isCancelled else { break }
                self?.isRecognizing = false
                if let match {
                    self?.applyRecognition(match)
                }
                try? await Task.sleep(for: .seconds(90))
            }
            self?.isRecognizing = false
        }
    }

    private func stopRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecognizing = false
    }

    private func applyRecognition(_ match: RecognizedTrack) {
        guard let title = match.title?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return
        }
        let artist = match.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = title != nowPlayingTitle || artist != nowPlayingArtist
        nowPlayingTitle = title
        nowPlayingArtist = artist
        publishNowPlaying()
        guard changed else { return }

        artworkTask?.cancel()
        artwork = nil
        if let rawURL = match.artworkURL, let url = URL(string: rawURL) {
            artworkTask = Task { [weak self] in
                let image = await RadioArtworkFetcher.shared.artwork(from: url)
                guard !Task.isCancelled else { return }
                self?.artwork = image
                self?.publishNowPlaying()
            }
        } else if let artist, !artist.isEmpty {
            artworkTask = Task { [weak self] in
                let image = await RadioArtworkFetcher.shared.artwork(
                    artist: artist,
                    title: title
                )
                guard !Task.isCancelled else { return }
                self?.artwork = image
                self?.publishNowPlaying()
            }
        }
    }

    private func installMediaCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]

        register(center.nextTrackCommand, offset: 1)
        register(center.skipForwardCommand, offset: 1)
        register(center.previousTrackCommand, offset: -1)
        register(center.skipBackwardCommand, offset: -1)
        updateMediaCommandAvailability()
    }

    private func register(_ command: MPRemoteCommand, offset: Int) {
        let target = command.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard
                    let self,
                    self.acceptsMediaCommands,
                    self.isPlaying,
                    NSApplication.shared.isActive
                else { return }
                self.cycleStation(by: offset)
            }
            return .success
        }
        mediaCommandTargets.append(
            MediaCommandRegistration(command: command, target: target)
        )
    }

    private func updateMediaCommandAvailability() {
        let enabled = acceptsMediaCommands && isPlaying
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = enabled
        center.previousTrackCommand.isEnabled = enabled
        center.skipForwardCommand.isEnabled = enabled
        center.skipBackwardCommand.isEnabled = enabled
    }

    private func publishNowPlaying() {
        guard acceptsMediaCommands, isPlaying else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let information: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle ?? selectedStation.name,
            MPMediaItemPropertyArtist: nowPlayingArtist ?? selectedStation.subtitle,
            MPMediaItemPropertyAlbumTitle: "\(selectedStation.frequency) FM",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: true
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = information
    }

    deinit {
        artworkTask?.cancel()
        recognitionTask?.cancel()
        for registration in mediaCommandTargets {
            registration.remove()
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

struct RadioWidget: View {
    @StateObject private var model = RadioPlayerModel()
    @EnvironmentObject private var settings: AppSettings

    private var stations: [RadioStation] {
        RadioStation.stations(hiding: settings.hiddenRadioStations, adding: settings.customRadioStations)
    }

    var body: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(model.stations) { station in
                        stationButton(station)
                    }
                }
                .padding(.horizontal, 12)
            }

            HStack(spacing: 13) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let artwork = model.artwork {
                            Image(nsImage: artwork)
                                .resizable()
                                .scaledToFill()
                        } else {
                            RoundedRectangle(cornerRadius: 11)
                                .fill(model.selectedStation.color.gradient)
                                .overlay {
                                    Image(systemName: "music.note")
                                        .font(.system(size: 32, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.9))
                                }
                        }
                    }
                    .frame(width: 94, height: 94)
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                    .overlay {
                        RoundedRectangle(cornerRadius: 15)
                            .stroke(Color.white.opacity(0.16))
                    }
                    .shadow(color: .black.opacity(0.32), radius: 12, y: 5)

                    Button {
                        model.togglePlayback()
                    } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 35, height: 35)
                            .background(.black.opacity(0.72))
                            .clipShape(Circle())
                            .overlay {
                                Circle().stroke(Color.white.opacity(0.22))
                            }
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.isPlaying ? Color.red : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(model.isPlaying ? "LIVE" : "READY")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(.secondary)
                        if model.isRecognizing {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.65)
                            Text("LISTENING")
                                .font(.system(size: 8, weight: .bold))
                                .tracking(0.7)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(model.selectedStation.name)
                        .font(.system(size: 16, weight: .semibold))
                        .environment(\.layoutDirection, .rightToLeft)
                    if let title = model.nowPlayingTitle {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        if let artist = model.nowPlayingArtist {
                            Text(artist)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else if model.isPlaying {
                        Text("Waiting for song information…")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $model.volume, in: 0...1)
                    .frame(maxWidth: 110)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 12)
        .onAppear {
            model.update(stations: stations, recognizesSongs: settings.recognizesSongs)
            model.setMediaCommandsActive(NSApplication.shared.isActive)
        }
        .onChange(of: stations) { _, stations in
            model.update(stations: stations, recognizesSongs: settings.recognizesSongs)
        }
        .onChange(of: settings.recognizesSongs) { _, recognizes in
            model.update(stations: stations, recognizesSongs: recognizes)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            model.setMediaCommandsActive(true)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didResignActiveNotification
            )
        ) { _ in
            model.setMediaCommandsActive(false)
        }
        .background {
            RadialGradient(
                colors: [model.selectedStation.color.opacity(0.12), .clear],
                center: .bottomLeading,
                startRadius: 10,
                endRadius: 260
            )
        }
    }

    private func stationButton(_ station: RadioStation) -> some View {
        let selected = model.selectedID == station.id
        return Button {
            model.select(station)
        } label: {
            VStack(spacing: 2) {
                Text(station.frequency)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(station.subtitle)
                    .font(.system(size: 7.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(selected ? station.color : .secondary)
            }
            .frame(minWidth: 62)
            .padding(.vertical, 7)
            .padding(.horizontal, 3)
            .background(selected ? station.color.opacity(0.15) : Color.white.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? station.color.opacity(0.55) : Color.white.opacity(0.07))
            }
        }
        .buttonStyle(.plain)
        .help("\(station.name) · \(station.frequency)FM")
    }
}
