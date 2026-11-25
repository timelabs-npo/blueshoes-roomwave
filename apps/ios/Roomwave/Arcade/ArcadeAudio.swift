import AVFoundation
import UIKit
import RoomwaveArcade

/// Original oscillator music and cues, synthesized once off the audio render thread.
/// Four reusable cue nodes bound polyphony; no source-node callback or streamed media.
@MainActor
final class ArcadeAudio: NSObject {
    private enum Cue: Int, CaseIterable { case bed, launch, landing, ring, boost, hit, finish }
    private let engine = AVAudioEngine()
    private let bed = AVAudioPlayerNode()
    private var voices: [AVAudioPlayerNode] = []
    private var buffers: [AVAudioPCMBuffer] = []
    private var voiceIndex = 0
    private let impact = UIImpactFeedbackGenerator(style: .soft)
    private let notification = UINotificationFeedbackGenerator()
    private var preferences = ArcadePreferences()
    private var running = false
    private var prepared = false
    private var finishTask: Task<Void, Never>?
    private(set) var notice: String?
    var onInterruption: (() -> Void)?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil)
    }

    func prepare() async {
        guard !prepared else { return }
        let samples = await Task.detached(priority: .utility) { Self.synthesize() }.value
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            notice = "Audio is unavailable. You can still play."; return
        }
        for sample in samples {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sample.count)), let channel = buffer.floatChannelData?[0] else {
                notice = "Audio is unavailable. You can still play."; return
            }
            buffer.frameLength = AVAudioFrameCount(sample.count)
            sample.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { channel.update(from: base, count: source.count) }
            }
            buffers.append(buffer)
        }
        engine.attach(bed)
        engine.connect(bed, to: engine.mainMixerNode, format: format)
        for _ in 0..<4 {
            let node = AVAudioPlayerNode()
            engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: format)
            voices.append(node)
        }
        engine.mainMixerNode.outputVolume = 0.65
        engine.prepare()
        prepared = true
    }

    func configure(_ preferences: ArcadePreferences, running: Bool) {
        finishTask?.cancel(); finishTask = nil
        self.preferences = preferences
        self.running = running
        guard running, preferences.soundEnabled, prepared else { stop(); return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if !engine.isRunning { try engine.start() }
            if !bed.isPlaying {
                bed.scheduleBuffer(buffers[Cue.bed.rawValue], at: nil, options: .loops, completionHandler: nil)
                bed.volume = 0.13
                bed.play()
            }
            if preferences.hapticsEnabled { impact.prepare() }
        } catch {
            stop()
            notice = "Audio could not start. You can still play."
        }
    }

    func update(speed: Double, charge: Double) {
        guard running, preferences.soundEnabled else { return }
        let energy = min(1, max(0, (speed - 10) / 20))
        bed.volume = Float(0.10 + energy * 0.10 + min(1, max(0, charge)) * 0.035)
        bed.pan = Float(min(1, max(0, charge)) * 0.12)
    }

    func play(_ event: SurfEvent) {
        let cue: Cue
        switch event.kind {
        case .takeoff: cue = .launch
        case .perfectLanding: cue = .landing
        case .ring: cue = .ring
        case .boost: cue = .boost
        case .hit: cue = .hit
        case .finish: cue = .finish
        default: return
        }
        if preferences.soundEnabled, engine.isRunning, buffers.count == Cue.allCases.count {
            let node = voices[voiceIndex]
            voiceIndex = (voiceIndex + 1) % voices.count
            node.stop()
            node.volume = cue == .hit ? 0.28 : 0.36
            node.scheduleBuffer(buffers[cue.rawValue], at: nil, options: [], completionHandler: nil)
            node.play()
        }
        guard preferences.hapticsEnabled else { return }
        switch event.kind {
        case .hit: notification.notificationOccurred(.warning)
        case .finish: notification.notificationOccurred(.success)
        default: impact.impactOccurred(intensity: CGFloat(min(0.7, max(0.2, event.intensity * 0.5))))
        }
    }

    /// Results keep only the short finish tail; all pause/background paths stop every voice.
    func endRun() {
        running = false
        bed.stop()
        finishTask?.cancel()
        finishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        running = false
        finishTask?.cancel(); finishTask = nil
        bed.stop()
        voices.forEach { $0.stop() }
        engine.pause()
    }

    @objc nonisolated private func interrupted(_ note: Notification) {
        let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
            == AVAudioSession.InterruptionType.began.rawValue
        guard began else { return }
        Task { @MainActor [weak self] in
            self?.stop(); self?.onInterruption?()
        }
    }

    @objc nonisolated private func routeChanged(_ note: Notification) {
        let unplugged = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
            == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
        guard unplugged else { return }
        Task { @MainActor [weak self] in
            self?.stop(); self?.onInterruption?()
        }
    }

    nonisolated private static func synthesize() -> [[Float]] {
        let sampleRate = 48_000.0
        let notes = [146.832, 220.0, 261.626, 293.665, 349.228, 293.665, 220.0, 174.614]
        let frequencies = [0.0, 280, 440, 880, 330, 92, 523.251]
        return (0..<7).map { cue in
            let duration = cue == 0 ? 4.0 : (cue == 6 ? 0.7 : 0.24)
            let count = Int(sampleRate * duration)
            return (0..<count).map { index in
                let t = Double(index) / sampleRate
                let value: Double
                if cue == 0 {
                    // An original eight-note D-minor pentatonic phrase over a soft D/A drone.
                    let beat = Int(t * 2) % notes.count
                    let local = t.truncatingRemainder(dividingBy: 0.5)
                    let pluck = sin(2 * .pi * notes[beat] * t) * exp(-local * 10) * 0.15
                    let drone = sin(2 * .pi * 55 * t) * 0.12 + sin(2 * .pi * 110 * t) * 0.05
                    value = drone + pluck
                } else {
                    let f = frequencies[cue]
                    let sweep = cue == 1 || cue == 4 ? 480.0 : (cue == 5 ? -80.0 : 0)
                    let attack = min(1, t / 0.008)
                    let decay = pow(max(0, 1 - t / duration), 2)
                    let fundamental = sin(2 * .pi * (f * t + sweep * t * t))
                    let overtone = sin(2 * .pi * f * 1.5 * t) * (cue == 5 ? 0.55 : 0.18)
                    value = (fundamental + overtone) * attack * decay * 0.5
                }
                return Float(value)
            }
        }
    }
}
