import SwiftUI

struct ContentView: View {
    @ObservedObject var model: RoomwaveModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text(model.sourceLabel)
                        .font(.headline)
                        .foregroundStyle(model.track?.source == .synthetic ? .orange : .cyan)
                        .accessibilityAddTraits(.isHeader)
                    Text(model.message).font(.callout)
                    switch model.phase {
                    case .idle:
                        Button("Use SYNTHETIC demo") { model.makeDemo() }
                        Button("Start device capture") { Task { await model.startCapture() } }
                            .disabled(!model.supportsCapture)
                        if !model.supportsCapture {
                            Text("Device capture disabled: ARKit world tracking with LiDAR mesh reconstruction is required. The demo uses invented points.")
                        }
                        Text("Camera access is requested only after Start. No capture is uploaded or recorded.")
                    case .requestingCamera:
                        ProgressView("Waiting for camera permission")
                        Button("Cancel") { model.reset() }
                    case .capturing:
                        ProgressView(value: Double(model.sampleCount), total: 2_048)
                        Text("\(model.sampleCount) local sampled vertices / 2,048 maximum")
                        Button("Finish capture and freeze route") { model.finishCapture() }
                        Button("Discard capture") { model.reset() }
                    case .preview, .racing, .result:
                        if let track = model.track {
                            TrackScene(track: track, race: model.race)
                                .frame(height: 320)
                                .accessibilityLabel("Frozen stylized circuit, orange gates and white player")
                            Text("Final game geometry • camera stopped")
                            if let race = model.race {
                                Text("\(race.status.rawValue.capitalized) • tick \(race.tick) / \(track.rules.durationTicks)")
                                Text("Banked \(race.bankedScore, specifier: "%.0f") · chain \(race.unbankedScore, specifier: "%.0f") · ×\(race.multiplier, specifier: "%.2f")")
                            }
                            if model.phase == .racing {
                                steeringPad
                                Button(model.bankArmed ? "Cancel armed bank" : "Arm bank at next gate") { model.bank() }.buttonStyle(.borderedProminent)
                                Button("Stop race") { model.stopForInactivity() }
                            } else {
                                Text("Review the entire route before racing or exporting. Derived geometry may reveal aspects of a room.")
                                Text("Rules: \(track.rules.tickRate) ticks/s, \(track.rules.durationTicks) ticks; bank at gates, crash beyond track width.")
                                Button(model.phase == .result ? "Start new race" : "Accept preview and race") { model.startRace() }
                                Button("Review local challenge JSON") { model.prepareReview() }
                                Button("Discard route / choose another source") { model.reset() }
                            }
                        }
                    }
                    Text("Local readiness build. Origin labels are not remote attestation. No public link, social connection, replay recording or video recording.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .buttonStyle(.bordered)
                .padding()
            }
            .navigationTitle("Roomwave")
            .sheet(item: $model.review) { review in ChallengeReviewView(review: review) }
        }
    }

    private var steeringPad: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 12)
                .fill(.teal.opacity(0.18))
                .overlay(Text("Drag left / right to steer\nRelease to stop steering").multilineTextAlignment(.center))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        model.steering = max(-1, min(1, Double(value.translation.width / max(geometry.size.width * 0.35, 1))))
                    }
                    .onEnded { _ in model.steering = 0 })
                .accessibilityLabel("Steering")
                .accessibilityValue(String(format: "%.1f", model.steering))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: model.steering = min(1, model.steering + 0.2)
                    case .decrement: model.steering = max(-1, model.steering - 0.2)
                    @unknown default: model.steering = 0
                    }
                }
        }
        .frame(height: 100)
    }
}
