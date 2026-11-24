import ARKit
import AVFoundation
import Combine
import Foundation
import RoomwaveCore
import UIKit
import simd

struct ChallengeReview: Identifiable {
    let id = UUID()
    let data: Data
    let trackID: String
}

@MainActor
final class RoomwaveModel: ObservableObject {
    enum Phase { case idle, requestingCamera, capturing, preview, racing, result }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var track: TrackDefinition?
    @Published private(set) var race: RaceState?
    @Published private(set) var message = "Choose an invented demo or explicitly start a device capture."
    @Published private(set) var sampleCount = 0
    @Published var review: ChallengeReview?
    @Published var steering = 0.0

    private let session = ARSession()
    private var captureTask: Task<Void, Never>?
    private var raceTask: Task<Void, Never>?
    private var operation = UUID()
    private var meshPoints: [UUID: [Vector3]] = [:]
    private var bankRequested = false
    private let maxAnchors = 32
    private let maxVerticesPerAnchor = 64

    var supportsCapture: Bool {
        ARWorldTrackingConfiguration.isSupported &&
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    var sourceLabel: String {
        switch track?.source {
        case .synthetic: "SYNTHETIC DEMO — invented points"
        case .arkitMesh: "DEVICE MESH — client-reported ARKit origin"
        case nil: phase == .capturing ? "LIVE DEVICE CAPTURE — local only" : "NO CAPTURE"
        }
    }

    func makeDemo() {
        reset()
        // Invented fixture, never presented as a measurement or relabeled as ARKit.
        let points = (0..<128).map { index -> Vector3 in
            let angle = Double(index) * 2 * .pi / 128
            return Vector3(x: 3 * cos(angle), y: Double(index % 5) * 0.2,
                           z: 2 * sin(angle))
        }
        freeze(ScanSample(captureID: "synthetic-demo", source: .synthetic, points: points))
    }

    func startCapture() async {
        reset()
        guard supportsCapture else {
            message = "Device mesh capture is unavailable. Use the clearly labeled synthetic demo."
            return
        }
        guard UIApplication.shared.applicationState == .active else {
            message = "Capture requires the active app. Tap Start again when Roomwave is active."
            return
        }
        phase = .requestingCamera
        let token = operation
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        // A permission dialog may outlive a background transition or Cancel.
        guard token == operation, phase == .requestingCamera else { return }
        guard allowed else {
            phase = .idle
            message = "Camera permission is denied or restricted. Capture is disabled; demo remains available."
            return
        }
        guard UIApplication.shared.applicationState == .active else {
            phase = .idle
            message = "Permission resolved while inactive. Tap Start again when Roomwave is active."
            return
        }
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.sceneReconstruction = .mesh
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        phase = .capturing
        message = "Move the device slowly while staying in a safe position. Collecting at most 2,048 vertices for 20 seconds; no camera preview or recording."
        captureTask = Task { [weak self] in
            for _ in 0..<80 {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.phase == .capturing, self.operation == token else { return }
                self.copyMeshSnapshot()
            }
            self?.finishCapture()
        }
    }

    private func copyMeshSnapshot() {
        guard let frame = session.currentFrame else { return }
        guard case .normal = frame.camera.trackingState else {
            message = "Waiting for normal AR tracking. Finish may fail if too little mesh was observed."
            return
        }
        for anchor in frame.anchors.compactMap({ $0 as? ARMeshAnchor }).prefix(maxAnchors) {
            guard meshPoints[anchor.identifier] != nil || meshPoints.count < maxAnchors else { continue }
            let vertices = anchor.geometry.vertices
            guard vertices.format == .float3, vertices.stride >= 12, vertices.count > 0 else { continue }
            let count = min(maxVerticesPerAnchor, vertices.count)
            var points: [Vector3] = []
            points.reserveCapacity(count)
            for slot in 0..<count {
                let index = slot * vertices.count / count
                let offset = vertices.offset + index * vertices.stride
                guard offset >= 0, offset + 12 <= vertices.buffer.length else { continue }
                let pointer = vertices.buffer.contents().advanced(by: offset)
                let x = pointer.loadUnaligned(as: Float.self)
                let y = pointer.advanced(by: 4).loadUnaligned(as: Float.self)
                let z = pointer.advanced(by: 8).loadUnaligned(as: Float.self)
                // Every anchor's local vertices enter the same session world frame.
                let world = anchor.transform * SIMD4<Float>(x, y, z, 1)
                guard world.x.isFinite, world.y.isFinite, world.z.isFinite else { continue }
                points.append(Vector3(x: Double(world.x), y: Double(world.y), z: Double(world.z)))
            }
            meshPoints[anchor.identifier] = points
        }
        sampleCount = meshPoints.values.reduce(0) { $0 + $1.count }
        message = "Device capture active: \(sampleCount) sampled vertices. Finish stops the camera before generating a route."
    }

    func finishCapture() {
        guard phase == .capturing else { return }
        session.pause()
        captureTask?.cancel()
        captureTask = nil
        // Stable ordering within this local capture; IDs never enter the challenge.
        let points = meshPoints.keys.sorted { $0.uuidString < $1.uuidString }
            .flatMap { meshPoints[$0] ?? [] }
        meshPoints.removeAll()
        freeze(ScanSample(captureID: UUID().uuidString, source: .arkitMesh, points: points))
    }

    private func freeze(_ sample: ScanSample) {
        session.pause()
        do {
            let normalized = try ScanNormalizer.normalize(sample)
            let generated = try TrackGenerator.makeTrack(from: normalized, seed: 27)
            guard generated.source == sample.source else {
                throw RoomwaveError.invalidTrack("Capture provenance changed")
            }
            let issues = TrackValidator.validate(generated)
            guard issues.isEmpty else {
                throw RoomwaveError.invalidTrack(issues.map(\.message).joined(separator: "; "))
            }
            track = generated
            phase = .preview
            message = "Capture stopped. Frozen stylized route ready for review. Race seated or standing still."
        } catch {
            track = nil
            phase = .idle
            message = "Could not create a valid route: \(error). No race or export is available."
        }
    }

    func startRace() {
        guard phase == .preview || phase == .result, let track else { return }
        session.pause()
        do {
            race = try RaceSimulation.initialState(rules: track.rules)
            steering = 0
            bankRequested = false
            phase = .racing
            message = "Drag one finger left/right. Bank applies only at a gate crossed on the next simulation tick."
            raceTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(1.0 / Double(track.rules.tickRate)))
                    } catch { return }
                    guard let self, self.phase == .racing, let state = self.race else { return }
                    do {
                        let input = RaceInput(tick: state.tick + 1, steering: self.steering, bank: self.bankRequested)
                        self.bankRequested = false
                        let next = try RaceSimulation.step(state: state, input: input, track: track)
                        self.race = next
                        if next.status != .running {
                            self.phase = .result
                            self.message = "Run \(next.status.rawValue). Score comes only from core race state."
                            return
                        }
                    } catch {
                        self.phase = .preview
                        self.message = "Race stopped: \(error)"
                        return
                    }
                }
            }
        } catch { message = "Race unavailable: \(error)" }
    }

    func bank() {
        if phase == .racing { bankRequested = true }
    }

    func prepareReview() {
        guard phase == .preview || phase == .result, let track else { return }
        do {
            let identity = try TrackIdentity.id(for: track)
            let descriptor = ChallengeDescriptor(schemaVersion: 1, trackID: identity, track: track)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            review = ChallengeReview(data: try encoder.encode(descriptor), trackID: identity)
        } catch { message = "Export unavailable: \(error)" }
    }

    func stopForInactivity() {
        operation = UUID()
        captureTask?.cancel()
        raceTask?.cancel()
        captureTask = nil
        raceTask = nil
        session.pause()
        meshPoints.removeAll()
        sampleCount = 0
        steering = 0
        bankRequested = false
        if phase == .capturing || phase == .requestingCamera {
            phase = .idle
            message = "Capture stopped on inactivity; local raw samples discarded. Start explicitly to capture again."
        } else if phase == .racing {
            phase = .preview
            race = nil
            message = "Race stopped on inactivity. Review the frozen route before a new run."
        }
    }

    func reset() {
        stopForInactivity()
        track = nil
        race = nil
        review = nil
        phase = .idle
    }
}
