import Foundation
import PhotosUI
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: RoomwaveModel
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoLoadError: String?
    @State private var layersExpanded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    switch model.phase {
                    case .idle:
                        sourceSelection
                    case .requestingCamera:
                        waitingCard(title: "Ready to look around?",
                                    detail: "Allow camera access to build a route from your space.")
                    case .analyzingPhoto:
                        waitingCard(title: "Finding your next route",
                                    detail: "Reading shapes and contrast in your photo on this device.")
                    case .capturing:
                        captureCard
                    case .preview, .racing, .result:
                        trackContent
                    }
                    Text("ROOMWAVE · PILOT")
                        .font(.caption2.weight(.medium))
                        .tracking(2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
                .padding(20)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background(RoomwaveTheme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .tint(RoomwaveTheme.accent)
            .preferredColorScheme(.dark)
            .sheet(item: $model.review) { review in
                ChallengeReviewView(review: review)
            }
            .alert("Photo could not be opened", isPresented: Binding(
                get: { photoLoadError != nil },
                set: { if !$0 { photoLoadError = nil } }
            )) {
                Button("OK", role: .cancel) { photoLoadError = nil }
            } message: {
                Text(photoLoadError ?? "Choose another photo and try again.")
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task { @MainActor in
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            throw PhotoSelectionError.empty
                        }
                        guard selectedPhoto == item else { return }
                        await model.importPhotoData(data)
                    } catch {
                        guard selectedPhoto == item else { return }
                        photoLoadError = "The selected photo is unavailable. If it is stored in iCloud, download it and try again."
                    }
                    if selectedPhoto == item { selectedPhoto = nil }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("BLUESHOES")
                    .font(.caption2.weight(.bold))
                    .tracking(3)
                    .foregroundStyle(RoomwaveTheme.accent)
                Text("Roomwave")
                    .font(.largeTitle.weight(.heavy))
            }
            Spacer(minLength: 12)
            if model.track != nil {
                Text(sourceName)
                    .font(.caption.weight(.bold))
                    .tracking(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoomwaveTheme.accent.opacity(0.12), in: Capsule())
                    .foregroundStyle(RoomwaveTheme.accent)
                    .accessibilityLabel("Route source: \(sourceName)")
            }
        }
    }

    private var sourceSelection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(RoomwaveTheme.accent)
                    .accessibilityHidden(true)
                Text("Your world.\nYour next run.")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("Turn a photo or a LiDAR scan into a stylized course. Steer through the bends. Save your chain before you fall.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .modifier(RoomwavePanel())

            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Label("Create from a photo", systemImage: "photo")
            }
            .buttonStyle(RoomwaveButtonStyle(primary: true))

            if selectedPhoto != nil {
                ProgressView("Loading selected photo…")
                    .font(.footnote)
            }

            Button {
                selectedPhoto = nil
                Task { await model.startCapture() }
            } label: {
                Label("Scan with LiDAR", systemImage: "viewfinder")
            }
            .buttonStyle(RoomwaveButtonStyle())
            .disabled(!model.supportsCapture)
            .opacity(model.supportsCapture ? 1 : 0.45)

            Button {
                selectedPhoto = nil
                model.makeDemo()
            } label: {
                Label("Try the demo course", systemImage: "play.fill")
            }
            .buttonStyle(RoomwaveButtonStyle())

            Text("Photos create an imagined map from image features, without measured room dimensions. LiDAR needs a supported device. The demo uses an invented scene.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            statusMessage
        }
    }

    private func waitingCard(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ProgressView().controlSize(.large)
            Text(title).font(.title2.weight(.bold))
            Text(detail).foregroundStyle(.secondary)
            Button("Cancel") {
                selectedPhoto = nil
                model.reset()
            }
            .buttonStyle(RoomwaveButtonStyle())
        }
        .modifier(RoomwavePanel())
    }

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Find a few big shapes")
                .font(.title2.weight(.bold))
            RoomCapturePreview(session: model.captureSession)
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(alignment: .topLeading) {
                    Label("SCANNING", systemImage: "record.circle")
                        .font(.caption.weight(.bold))
                        .padding(10)
                        .background(.black.opacity(0.7), in: Capsule())
                        .padding(12)
                }
                .accessibilityLabel("Live camera view used to scan the surrounding space")
            Text("Move slowly around a small area with large surfaces and objects. Finish to see the course before racing.")
                .foregroundStyle(.secondary)
            statusMessage
            Button("Finish scan") { model.finishCapture() }
                .buttonStyle(RoomwaveButtonStyle(primary: true))
            Button("Discard scan") { model.reset() }
                .buttonStyle(RoomwaveButtonStyle())
        }
    }

    @ViewBuilder
    private var trackContent: some View {
        if let track = model.track {
            VStack(alignment: .leading, spacing: 16) {
                if model.phase == .result {
                    Text(model.race?.status == .finished ? "Run complete." : "One more run?")
                        .font(.largeTitle.weight(.heavy))
                    Text(model.race?.status == .finished
                         ? "Your remaining chain is saved. Try a faster line next time."
                         : "You left the course. Your banked score stays safe.")
                        .foregroundStyle(.secondary)
                }

                TrackScene(track: track, race: model.race, steering: model.steering,
                           avatarSkeleton: model.avatarSkeleton, avatarMuscle: model.avatarMuscle,
                           avatarSkin: model.avatarSkin, avatarCoat: model.avatarCoat)
                    .frame(height: model.phase == .racing ? 390 : 320)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24)
                            .strokeBorder(RoomwaveTheme.accent.opacity(0.25), lineWidth: 1)
                    }
                    .accessibilityLabel("Stylized course with checkpoint gates and an animated rider")

                if let race = model.race {
                    HStack(spacing: 14) {
                        RoomwaveStat(label: "Saved", value: String(format: "%.0f", race.bankedScore), highlighted: true)
                        RoomwaveStat(label: "At risk", value: String(format: "%.0f", race.unbankedScore))
                        RoomwaveStat(label: "Chain", value: String(format: "×%.2f", race.multiplier))
                    }
                    .modifier(RoomwavePanel())
                }

                if model.phase == .racing {
                    raceControls
                } else {
                    if model.phase == .preview {
                        Text("Your course is ready")
                            .font(.title2.weight(.bold))
                        Text("Steer to counter the bends. Pass a gate to grow your chain, or arm Bank to save it and slow down.")
                            .foregroundStyle(.secondary)
                    }
                    Button(model.phase == .result ? "Race again" : "Start run") { model.startRace() }
                        .buttonStyle(RoomwaveButtonStyle(primary: true))
                    avatarControls
                    HStack(spacing: 12) {
                        Button { model.prepareReview() } label: {
                            Label("Export course", systemImage: "square.and.arrow.up")
                        }
                        Button { model.reset() } label: {
                            Label("New course", systemImage: "plus")
                        }
                    }
                    .buttonStyle(RoomwaveButtonStyle())
                    Text("Export includes the stylized course and its rules. Review it first: a derived shape may still reveal features of the original space.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    statusMessage
                }
            }
        }
    }

    private var raceControls: some View {
        VStack(spacing: 12) {
            steeringPad
            Button { model.bank() } label: {
                Label(model.bankArmed ? "Bank armed · tap to cancel" : "Bank at the next gate",
                      systemImage: model.bankArmed ? "checkmark.shield.fill" : "shield")
            }
            .buttonStyle(RoomwaveButtonStyle(primary: model.bankArmed))
            Button("End run") { model.stopForInactivity() }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    private var steeringPad: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 18)
                .fill(RoomwaveTheme.accent.opacity(0.10))
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.left.and.right")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(RoomwaveTheme.accent)
                        Text("Drag to steer · release to stop steering")
                            .font(.footnote.weight(.medium))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 12)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        model.steering = max(-1, min(1, Double(value.translation.width / max(geometry.size.width * 0.35, 1))))
                    }
                    .onEnded { _ in model.steering = 0 })
                .accessibilityLabel("Steering")
                .accessibilityValue(String(format: "%.1f", model.steering))
                .accessibilityHint("Adjust left or right to counter the turn. Return to zero to stop steering.")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: model.steering = min(1, model.steering + 0.2)
                    case .decrement: model.steering = max(-1, model.steering - 0.2)
                    @unknown default: model.steering = 0
                    }
                }
        }
        .frame(height: 95)
    }

    private var avatarControls: some View {
        DisclosureGroup("Rider layers", isExpanded: $layersExpanded) {
            VStack(spacing: 14) {
                Toggle("Skeleton overlay", isOn: $model.avatarSkeleton)
                Toggle("Muscle overlay", isOn: $model.avatarMuscle)
                Toggle("Skin", isOn: $model.avatarSkin)
                Toggle("Coat", isOn: $model.avatarCoat)
                Text("The inner layers are stylized animation overlays.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 16)
        }
        .font(.subheadline.weight(.medium))
        .modifier(RoomwavePanel())
    }

    private var statusMessage: some View {
        Text(model.message)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var sourceName: String {
        switch model.track?.source {
        case .arkitMesh: "LIDAR"
        case .photoDerived: "PHOTO"
        case .synthetic: "DEMO"
        case nil: ""
        }
    }
}

private enum PhotoSelectionError: Error { case empty }
