import SwiftUI
import PhotosUI
import RoomwaveArcade
import RoomwaveCreator

/// Optional creation has its own lifetime; it never blocks the first Play.
@MainActor
struct ArcadeCreatorView: View {
    let onCourse: (CompiledSurfCourse) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var capture = RoomwaveModel()
    @State private var selection: PhotosPickerItem?
    @State private var analyzing = false
    @State private var candidate: CompiledSurfCourse?
    @State private var message = "Turn the shapes around you into a new current."

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("YOUR WORLD.\nYOUR CURRENT.")
                        .font(.system(size: 30, weight: .black, design: .rounded))
                    Text("Choose a picture, or scan a space with LiDAR. Shapes inspire the route while the opening encounters stay familiar.")
                        .foregroundStyle(.secondary)
                    PhotosPicker(selection: $selection, matching: .images) {
                        Label("Create from a photo", systemImage: "photo.on.rectangle.angled")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .disabled(analyzing || capture.phase == .capturing || capture.phase == .requestingCamera)
                    .accessibilityIdentifier("creator.photo")

                    if capture.phase == .capturing {
                        RoomCapturePreview(session: capture.captureSession)
                            .frame(height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .accessibilityLabel("Camera preview for local LiDAR capture")
                        Text(capture.message).font(.footnote).foregroundStyle(.secondary)
                        Button("Finish scan") { capture.finishCapture() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            selection = nil
                            candidate = nil
                            Task { await capture.startCapture() }
                        } label: {
                            Label("Create with LiDAR", systemImage: "viewfinder")
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!capture.supportsCapture || analyzing || capture.phase == .requestingCamera)
                        if !capture.supportsCapture {
                            Text("LiDAR is unavailable on this device. Photo creation is available.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }

                    if analyzing || capture.phase == .requestingCamera {
                        ProgressView(analyzing ? "Reading shapes on this device…" : "Waiting for camera permission…")
                    }
                    Text(message).font(.callout).accessibilityIdentifier("creator.status")
                    if let candidate {
                        Text(candidate.definition.title).font(.title2.bold())
                        Text("A stylized course inspired by your input. Preview it, then ride.")
                            .foregroundStyle(.secondary)
                        Button("Use this course") {
                            onCourse(candidate)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("creator.use")
                    }
                    Text("Your picture and raw scan stay on this device and are discarded after analysis. Generated routes are creative interpretations, not measured room reconstructions. Custom routes are local in this beta.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Link("Privacy", destination: URL(string: "https://github.com/timelabs-npo/blueshoes-roomwave/blob/main/docs/PRIVACY.md")!)
                        .font(.footnote)
                }
                .padding(24)
            }
            .background(Color(red: 0.025, green: 0.035, blue: 0.09))
            .navigationTitle("Create a current")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            capture.onCaptureSample = { sample in
                do {
                    candidate = try InspiredCourseFactory.make(from: sample)
                    message = "Your scan shaped a new current."
                } catch {
                    candidate = nil
                    message = "Could not create a safe route: \(error.localizedDescription)"
                }
            }
        }
        .task(id: selection) {
            guard let selection else { return }
            analyzing = true
            candidate = nil
            defer { analyzing = false }
            do {
                guard let data = try await selection.loadTransferable(type: Data.self) else {
                    message = "This picture could not be read. Choose another still photo."
                    return
                }
                let sample = try await PhotoMapImporter.sample(from: data)
                try Task.checkCancellation()
                candidate = try InspiredCourseFactory.make(from: sample)
                message = "Your photo shaped a new current."
            } catch is CancellationError {
                // Closing the creator cancels local analysis normally.
            } catch {
                message = "Could not use this photo: \(error.localizedDescription)"
            }
        }
        .onChange(of: capture.message) { _, value in
            if capture.phase == .idle && candidate == nil { message = value }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || (phase == .inactive && capture.phase != .requestingCamera) {
                capture.stopForInactivity()
                selection = nil
            }
        }
        .onDisappear {
            capture.onCaptureSample = nil
            capture.reset()
            selection = nil
        }
    }
}
