import AVFoundation
import UIKit
import RoomwaveArcade

/// Original oscillator music and cues, synthesized once off the audio render thread.
/// Four reusable cue nodes bound polyphony; no source-node callback or streamed media.
@MainActor
final class ArcadeAudio: NSObject {
    private enum Cue: Int, CaseIterable { case bed, launch, landing, ring, boost, hit, finish }
    private enum SessionState: Equatable { case inactive, active, uncertain }
    private enum SessionOperation: Equatable { case activating, deactivating }
    private let session = AVAudioSession.sharedInstance()
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
    private var preparationTask: Task<[[Float]], Never>?
    private var finishTask: Task<Void, Never>?
    private var finishTail = false
    private var interruptionActive = false
    private var generation: UInt64 = 0
    private var sessionState: SessionState = .inactive
    private var sessionOperation: SessionOperation?
    private var operationGeneration: UInt64 = 0
    private var failedActivationGeneration: UInt64?
    private var failedDeactivationGeneration: UInt64?
    private(set) var notice: String?
    var onInterruption: (() -> Void)?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(becameInactive(_:)),
            name: AVAudioSession.didBecomeInactiveNotification, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(resumptionRecommended(_:)),
            name: AVAudioSession.resumptionRecommendationNotification, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil)
    }

    func prepare() async {
        guard !prepared else { return }
        if preparationTask == nil {
            preparationTask = Task.detached(priority: .utility) { Self.synthesize() }
        }
        guard let preparationTask else { return }
        let samples = await preparationTask.value
        // Concurrent bootstrap calls share synthesis and cannot attach a second voice graph.
        guard !prepared, !Task.isCancelled else { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            notice = "Audio is unavailable. You can still play."; return
        }
        var preparedBuffers: [AVAudioPCMBuffer] = []
        preparedBuffers.reserveCapacity(Cue.allCases.count)
        for sample in samples {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                frameCapacity: AVAudioFrameCount(sample.count)), let channel = buffer.floatChannelData?[0] else {
                notice = "Audio is unavailable. You can still play."; return
            }
            buffer.frameLength = AVAudioFrameCount(sample.count)
            sample.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { channel.update(from: base, count: source.count) }
            }
            preparedBuffers.append(buffer)
        }
        do {
            // Configure once during preparation, before the first Play action.
            // Ambient preserves silent-switch behavior and mixing with other audio.
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        } catch {
            notice = "Audio is unavailable. You can still play."; return
        }
        buffers = preparedBuffers
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
        self.preparationTask = nil
        reconcileSession()
    }

    func configure(_ preferences: ArcadePreferences, running: Bool) {
        generation &+= 1
        finishTask?.cancel(); finishTask = nil
        finishTail = false
        self.preferences = preferences
        self.running = running && !interruptionActive
        if !wantsAudio { silenceGraph() }
        reconcileSession()
        if self.running, preferences.hapticsEnabled { impact.prepare() }
    }

    private var wantsAudio: Bool {
        (running || finishTail) && preferences.soundEnabled && prepared && !interruptionActive
            && failedActivationGeneration != generation
    }

    /// There is at most one platform activation/deactivation in flight. Its completion
    /// reconciles the latest intent; cancellation never lets an old callback start playback.
    /// iOS 27 provides these nonblocking APIs; the engine and voice graph stay on MainActor.
    /// https://developer.apple.com/documentation/avfaudio/avaudiosession/activate(options:completionhandler:)
    /// https://developer.apple.com/documentation/avfaudio/avaudiosession/deactivate(options:completionhandler:)
    private func reconcileSession() {
        guard sessionOperation == nil else { return }
        if wantsAudio {
            guard sessionState != .active else { startGraphIfWanted(); return }
            sessionOperation = .activating
            operationGeneration = generation
            let requestGeneration = generation
            session.activate(options: []) { [weak self] activated, error in
                let hadError = error != nil
                Task { @MainActor [weak self] in
                    self?.activationFinished(requestGeneration, activated: activated, hadError: hadError)
                }
            }
        } else if sessionState != .inactive, failedDeactivationGeneration != generation {
            // Every stop path silences/pauses the graph before requesting deactivation.
            silenceGraph()
            sessionOperation = .deactivating
            operationGeneration = generation
            let requestGeneration = generation
            session.deactivate(options: []) { [weak self] deactivated, error in
                let hadError = error != nil
                Task { @MainActor [weak self] in
                    self?.deactivationFinished(requestGeneration, deactivated: deactivated, hadError: hadError)
                }
            }
        }
    }

    private func activationFinished(_ requestGeneration: UInt64, activated: Bool, hadError: Bool) {
        guard sessionOperation == .activating, operationGeneration == requestGeneration else { return }
        sessionOperation = nil
        sessionState = hadError ? .uncertain : (activated ? .active : .inactive)
        if (!activated || hadError), requestGeneration == generation {
            failedActivationGeneration = generation
            notice = "Audio could not start. You can still play."
        }
        // Pause/background/sound-off may have arrived while activation was pending.
        // A successful stale activation is released if the current intent is silent.
        reconcileSession()
    }

    private func deactivationFinished(_ requestGeneration: UInt64, deactivated: Bool, hadError: Bool) {
        guard sessionOperation == .deactivating, operationGeneration == requestGeneration else { return }
        sessionOperation = nil
        sessionState = deactivated && !hadError ? .inactive : .uncertain
        if (!deactivated || hadError), requestGeneration == generation {
            failedDeactivationGeneration = generation
            notice = "Audio could not be released. Playback is stopped."
        }
        // A newer explicit Resume waits for deactivation, then requests a fresh activation.
        // Failed operations are not retried indefinitely for the same generation.
        reconcileSession()
    }

    private func startGraphIfWanted() {
        guard wantsAudio, running, sessionState == .active else { return }
        do {
            if !engine.isRunning { try engine.start() }
            if !bed.isPlaying {
                bed.scheduleBuffer(buffers[Cue.bed.rawValue], at: nil, options: .loops, completionHandler: nil)
                bed.volume = 0.13
                bed.play()
            }
            notice = nil
        } catch {
            failedActivationGeneration = generation
            silenceGraph()
            notice = "Audio could not start. You can still play."
            reconcileSession()
        }
    }

    func update(speed: Double, charge: Double) {
        guard running, preferences.soundEnabled, engine.isRunning else { return }
        let energy = min(1, max(0, (speed - 10) / 20))
        bed.volume = Float(0.10 + energy * 0.10 + min(1, max(0, charge)) * 0.035)
        bed.pan = Float(min(1, max(0, charge)) * 0.12)
    }

    func play(_ event: SurfEvent) {
        guard running else { return }
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
        if preferences.soundEnabled, engine.isRunning, buffers.count == Cue.allCases.count, voices.count == 4 {
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
        generation &+= 1
        running = false
        bed.stop()
        finishTask?.cancel()
        finishTail = preferences.soundEnabled && engine.isRunning && sessionState == .active
            && sessionOperation == nil && !interruptionActive
        guard finishTail else {
            finishTask = nil
            silenceGraph()
            reconcileSession()
            return
        }
        let tailGeneration = generation
        finishTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(800)) }
            catch { return }
            guard !Task.isCancelled, let self, self.generation == tailGeneration else { return }
            self.stop()
        }
    }

    func stop() {
        generation &+= 1
        running = false
        finishTail = false
        finishTask?.cancel(); finishTask = nil
        silenceGraph()
        reconcileSession()
    }

    private func silenceGraph() {
        bed.stop()
        voices.forEach { $0.stop() }
        engine.pause()
    }

    @objc nonisolated private func becameInactive(_ note: Notification) {
        guard let context = note.userInfo?[AVAudioSession.deactivationContextKey]
                as? AVAudioSession.DeactivationContext, context.source == .system else { return }
        // Our own async deactivate emits source .app; its completion owns that transition.
        // Muting sound must not masquerade as a system interruption and pause the game.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.interruptionActive = true
            // An in-flight completion still owns its transition and must reconcile
            // the now-cancelled playback intent.
            if self.sessionOperation == nil { self.sessionState = .inactive }
            self.stop()
            self.onInterruption?()
        }
    }

    @objc nonisolated private func resumptionRecommended(_ note: Notification) {
        guard let context = note.userInfo?[AVAudioSession.resumptionContextKey]
                as? AVAudioSession.ResumptionContext else { return }
        switch context.recommendation {
        case .shouldResume, .shouldNotResume:
            // Both recommendations leave gameplay/audio paused. A later explicit Play
            // or Resume may request activation; neither notification starts playback.
            Task { @MainActor [weak self] in self?.interruptionActive = false }
        @unknown default:
            break
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
                    let attack = min(1, local / 0.006)
                    let pluck = sin(2 * .pi * notes[beat] * t) * attack * exp(-local * 10) * 0.15
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
