import AVFoundation
import Darwin
import UIKit
import RoomwaveArcade

/// Live cues and a local radio rotation. Synthesized music is an offline fallback.
@MainActor
final class ArcadeAudio: NSObject {
    private enum Cue: Int, CaseIterable { case launch, landing, ring, boost, hit, finish }
    private enum Stem: Int, CaseIterable { case pulse, drive, air }
    private enum SessionState: Equatable { case inactive, active, uncertain }
    private enum SessionOperation: Equatable { case activating, deactivating }
    private let session = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private var music: [AVAudioPlayerNode] = []
    private var lastMusicMixTime: TimeInterval?
    private var musicEnergy = 0.0
    private var radio: AVAudioPlayer?
    private var radioIndex = -1
    private var radioUnavailable = false
    private(set) var playedRadioTrack: ArcadeRadioTrack?
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
        preparedBuffers.reserveCapacity(Stem.allCases.count + Cue.allCases.count)
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
        for _ in Stem.allCases {
            let node = AVAudioPlayerNode()
            engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: format)
            music.append(node)
        }
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

    func beginNewRace() {
        stopMusic()
        radio?.stop()
        radio = nil
        let count = ArcadeRadioTrack.rotation.count
        radioIndex = count == 0 ? -1 : (radioIndex + 1) % count
        radioUnavailable = false
        playedRadioTrack = nil
    }

    private func startRadio() -> Bool {
        guard !radioUnavailable, ArcadeRadioTrack.rotation.indices.contains(radioIndex) else {
            return false
        }
        let track = ArcadeRadioTrack.rotation[radioIndex]
        if radio == nil {
            guard let url = track.url, let player = try? AVAudioPlayer(contentsOf: url) else {
                radioUnavailable = true
                return false
            }
            player.numberOfLoops = -1
            player.volume = 0.23
            radio = player
        }
        guard let radio, radio.isPlaying || radio.play() else {
            radio = nil
            radioUnavailable = true
            return false
        }
        playedRadioTrack = track
        return true
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
            if startRadio() {
                notice = nil
                return
            }
            if lastMusicMixTime == nil {
                // All stems have exactly the same length and start at one host time.
                // Schedule once per run/resume. Intensity never replaces or seeks loops.
                let host = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.025)
                let downbeat = AVAudioTime(hostTime: host)
                for (index, node) in music.enumerated() {
                    node.scheduleBuffer(buffers[index], at: nil, options: .loops, completionHandler: nil)
                    node.volume = index == Stem.pulse.rawValue ? 0.34 : 0
                    try node.playAudio(at: downbeat)
                }
                lastMusicMixTime = ProcessInfo.processInfo.systemUptime
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
        guard running, preferences.soundEnabled, engine.isRunning,
              let previousTime = lastMusicMixTime else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lastMusicMixTime = now
        let dt = min(0.25, max(0, now - previousTime))
        let target = min(1, max(0, (speed - 10) / 20 + 0.20 * charge))
        // A short swell on acceleration; release more slowly so the rhythm holds
        // through landings. Percussion and the high arpeggio emerge independently.
        let tau = target > musicEnergy ? 0.19 : 0.54
        musicEnergy += (target - musicEnergy) * (1 - exp(-dt / tau))
        let lift = max(0, (musicEnergy - 0.42) / 0.58)
        music[Stem.drive.rawValue].volume = Float(0.34 * musicEnergy)
        music[Stem.air.rawValue].volume = Float(0.29 * lift)
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
        if preferences.soundEnabled, engine.isRunning, buffers.count == Stem.allCases.count + Cue.allCases.count, voices.count == 4 {
            let node = voices[voiceIndex]
            voiceIndex = (voiceIndex + 1) % voices.count
            node.stop()
            node.volume = cue == .hit ? 0.28 : 0.36
            node.scheduleBuffer(buffers[Stem.allCases.count + cue.rawValue], at: nil, options: [], completionHandler: nil)
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
        stopMusic()
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

    private func stopMusic() {
        radio?.pause()
        music.forEach { $0.stop() }
        lastMusicMixTime = nil
        musicEnergy = 0
    }

    private func silenceGraph() {
        stopMusic()
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
        // Original four-bar D minor racing loop. At 144 BPM / 48 kHz, every
        // sixteenth is exactly 5,000 frames; all three loops are sample-aligned.
        let sampleRate = 48_000.0
        let framesPerStep = 5_000
        let steps = 64
        let loopFrames = steps * framesPerStep
        var pulse = [Float](repeating: 0, count: loopFrames)
        var drive = pulse
        var air = pulse
        let harmony = [38, 34, 36, 33] // D, B-flat, C, A
        let arp: [[Int]] = [[62, 69, 65, 72], [58, 65, 62, 69],
                            [60, 67, 64, 70], [57, 64, 60, 67]]
        let riff = [0, -1, 0, 12, 0, -1, 7, -1, 0, 12, -1, 0, 0, -1, 7, 12]
        var random: UInt32 = 0x8b251121

        func wave(_ cycles: Double) -> Double { sin(2 * .pi * cycles) }
        func frequency(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }
        func envelope(_ time: Double, end: Double, attack: Double, release: Double) -> Double {
            min(1, min(time / attack, max(0, (end - time) / release)))
        }

        for step in 0..<steps {
            let bar = step / 16
            let inBar = step % 16
            let bass = riff[inBar]
            let bassFrequency = bass >= 0 ? frequency(harmony[bar] + bass) : 0
            let topFrequency = frequency(arp[bar][(inBar / 2 + inBar % 2) % 4])
            for frame in 0..<framesPerStep {
                let index = step * framesPerStep + frame
                let t = Double(frame) / sampleRate
                let length = Double(framesPerStep - 1) / sampleRate
                let gate = envelope(t, end: length, attack: 0.004, release: 0.012)
                // A swept kick and a syncopated bass, with bounded harmonics.
                let kickPhase = 46 * t + 87 * (1 - exp(-t * 52)) / 52
                let kick = inBar % 4 == 0 ? 0.34 * wave(kickPhase) * exp(-28 * t) : 0
                let b = bassFrequency * t
                let bassTone = bass >= 0 ? (wave(b) + 0.31 * wave(2 * b) + 0.15 * wave(3 * b))
                    * 0.15 * exp(-9 * t) : 0
                pulse[index] = Float(gate * (kick + bassTone))

                // Deterministic noise for claps and offbeat hats; never a sampled loop.
                random = random &* 1_664_525 &+ 1_013_904_223
                let noise = Double(random >> 8) / 8_388_608 - 1
                let clap = inBar % 8 == 4 ? (noise * 0.17 + 0.07 * wave(177 * t))
                    * exp(-35 * t) : 0
                let openHat = inBar % 4 == 2
                let hatLevel = openHat ? 0.16 : (inBar % 2 == 1 ? 0.075 : 0)
                let hat = noise * wave(8_200 * t) * hatLevel * exp((openHat ? -43 : -92) * t)
                drive[index] = Float(gate * (clap + hat))

                // Glassy upper line fades in only at speed. Accent the offbeat instead
                // of layering another sound on top of every kick.
                let p = topFrequency * t
                let lead = wave(p + 0.17 * wave(2 * p)) + 0.22 * wave(3 * p)
                let accent = inBar % 4 == 2 ? 0.25 : (inBar % 2 == 1 ? 0.14 : 0)
                air[index] = Float(gate * lead * accent * exp(-19 * t))
            }
        }

        let frequencies = [280.0, 440, 880, 330, 92, 523.251]
        let cues = frequencies.enumerated().map { index, f in
            let duration = index == 5 ? 0.7 : 0.24
            let count = Int(sampleRate * duration)
            return (0..<count).map { frame -> Float in
                let t = Double(frame) / sampleRate
                let sweep = index == 0 || index == 3 ? 480.0 : (index == 4 ? -80.0 : 0)
                let attack = min(1, t / 0.008)
                let decay = pow(max(0, 1 - t / duration), 2)
                let fundamental = wave(f * t + sweep * t * t)
                let overtone = wave(f * 1.5 * t) * (index == 4 ? 0.55 : 0.18)
                return Float((fundamental + overtone) * attack * decay * 0.5)
            }
        }
        return [pulse, drive, air] + cues
    }
}
