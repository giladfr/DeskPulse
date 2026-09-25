@preconcurrency import AVFoundation
import SwiftUI

/// Plays the capture card's audio (the other laptop's sound) on the Mac.
///
/// It runs its own capture session so the video session and its chosen mode are
/// never reconfigured, and a missing audio device or permission only affects sound.
@MainActor
final class HDMIAudio: ObservableObject {
    enum Status: Equatable {
        case off
        case playing(String)
        case noDevice
        case denied
    }

    struct Input: Identifiable, Hashable {
        let id: String
        let name: String
    }

    nonisolated private static let volumeKey = "hdmi.audio-volume.v1"
    nonisolated private static let mutedKey = "hdmi.audio-muted.v1"
    nonisolated private static let inputKey = "hdmi.audio-input.v1"

    @Published private(set) var status: Status = .off
    @Published private(set) var inputs: [Input] = []
    @Published var volume: Double = UserDefaults.standard.object(forKey: HDMIAudio.volumeKey) as? Double ?? 0.8 {
        didSet {
            UserDefaults.standard.set(volume, forKey: Self.volumeKey)
            applyVolume()
        }
    }
    @Published var isMuted: Bool = UserDefaults.standard.bool(forKey: HDMIAudio.mutedKey) {
        didSet {
            UserDefaults.standard.set(isMuted, forKey: Self.mutedKey)
            applyVolume()
        }
    }
    /// A specific audio input's ID, or nil to match the capture card automatically.
    @Published var inputChoice: String? = UserDefaults.standard.string(forKey: HDMIAudio.inputKey) {
        didSet {
            UserDefaults.standard.set(inputChoice, forKey: Self.inputKey)
            if isActive { configure() }
        }
    }

    private let session = AVCaptureSession()
    private let preview = AVCaptureAudioPreviewOutput()
    private let queue = DispatchQueue(label: "com.giladfride.DeskPulse.hdmi-audio", qos: .userInteractive)
    private var videoDeviceName = ""
    private var isActive = false
    private var generation = 0

    init() {
        if session.canAddOutput(preview) {
            session.addOutput(preview)
        }
        applyVolume()
    }

    /// Starts sound from the audio input that belongs to the named video device.
    func start(matching videoDeviceName: String) {
        guard !isActive || videoDeviceName != self.videoDeviceName else { return }
        isActive = true
        self.videoDeviceName = videoDeviceName
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { @Sendable [weak self] allowed in
                Task { @MainActor in
                    guard let self, self.isActive else { return }
                    if allowed {
                        self.configure()
                    } else {
                        self.status = .denied
                    }
                }
            }
        default:
            status = .denied
        }
    }

    func stop() {
        isActive = false
        generation &+= 1
        status = .off
        let session = session
        queue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() {
        generation &+= 1
        let generation = generation
        let session = session
        let choice = inputChoice
        let videoDeviceName = videoDeviceName
        queue.async { [weak self] in
            let devices = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio,
                position: .unspecified
            ).devices
            let inputs = devices.map { Input(id: $0.uniqueID, name: $0.localizedName) }
            let device = choice.flatMap { id in devices.first { $0.uniqueID == id } }
                ?? Self.cardAudioDevice(in: devices, videoDeviceName: videoDeviceName)

            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            var status = Status.noDevice
            if let device,
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
                status = .playing(device.localizedName)
            }
            session.commitConfiguration()
            if case .playing = status {
                if !session.isRunning { session.startRunning() }
            } else if session.isRunning {
                session.stopRunning()
            }

            Task { @MainActor in
                guard let self, generation == self.generation, self.isActive else { return }
                self.inputs = inputs
                self.status = status
            }
        }
    }

    /// The capture card's own audio input. Deliberately never falls back to another
    /// microphone, which would play the room (or the Mac's own speakers) back.
    nonisolated private static func cardAudioDevice(
        in devices: [AVCaptureDevice],
        videoDeviceName: String
    ) -> AVCaptureDevice? {
        let video = videoDeviceName.lowercased()
        let knownNames = ["ugreen", "15389", "cm629"]
        return devices.first { $0.localizedName.lowercased() == video }
            ?? devices.first { device in
                let name = device.localizedName.lowercased()
                return knownNames.contains { name.contains($0) }
                    || (!video.isEmpty && (name.contains(video) || video.contains(name)))
            }
    }

    private func applyVolume() {
        let preview = preview
        let level = isMuted ? 0 : Float(volume)
        queue.async {
            preview.volume = level
        }
    }
}

/// Mute, volume, and input choice for the HDMI screen's sound.
struct HDMIAudioControls: View {
    @ObservedObject var audio: HDMIAudio

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    audio.isMuted.toggle()
                } label: {
                    Image(systemName: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 20)
                }
                .buttonStyle(.borderless)
                .help(audio.isMuted ? "Unmute" : "Mute")
                Slider(value: $audio.volume, in: 0...1)
                    .disabled(audio.isMuted)
            }
            .disabled(!isPlaying)

            Picker("Audio input", selection: $audio.inputChoice) {
                Text("Capture card (automatic)").tag(String?.none)
                ForEach(audio.inputs) { input in
                    Text(input.name).tag(Optional(input.id))
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var isPlaying: Bool {
        if case .playing = audio.status { return true }
        return false
    }

    private var statusText: String {
        switch audio.status {
        case .off:
            "Sound starts with the picture."
        case .playing(let name):
            "Playing sound from \(name)."
        case .noDevice:
            "No audio input was found for the capture card. Choose one below if it has a different name."
        case .denied:
            "Microphone access is off, which DeskPulse needs to hear the capture card. Enable it in System Settings → Privacy & Security → Microphone."
        }
    }
}
