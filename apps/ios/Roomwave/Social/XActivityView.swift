import SwiftUI
import RoomwaveCreator

@MainActor
struct XActivityView: View {
    @ObservedObject var client: XActivityClient
    let onCurrent: (ViralCurrent) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source: Source = .personal
    @State private var query = "#TwitterSurfer OR #Roomwave"

    private enum Source: String, CaseIterable, Identifiable {
        case personal = "My activity", community = "Community event"
        var id: String { rawValue }
        var kind: ViralFeedKind { self == .personal ? .personal : .community }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("RIDE THE\nCONVERSATION.")
                        .font(.system(size: 32, weight: .black, design: .rounded))
                    Text("Read real X engagement to shape a current. Likes, reposts, replies and quotes influence the course; timing and skill earn your score.")
                        .foregroundStyle(.secondary)

                    Label(client.currentlyConnected ? "X connected" : "Offline play available",
                          systemImage: client.currentlyConnected ? "checkmark.shield" : "gamecontroller")
                        .font(.headline)
                        .accessibilityIdentifier("x.connection")

                    if !client.isConfigured {
                        Text("X Developer registration is pending. This build has no public X client ID, so live activity is unavailable. LiDAR creation and the arcade courses are available without X.")
                            .padding(16).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityIdentifier("x.unavailable")
                    }

                    Picker("Current source", selection: $source) {
                        ForEach(Source.allCases) { source in Text(source.rawValue).tag(source) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(client.isLoading)
                    .accessibilityIdentifier("x.source")

                    if source == .personal {
                        Text("Uses the public metrics of up to 10 of your latest posts. This build does not read your home timeline, private messages or mentions.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        TextField("Community query", text: $query, axis: .vertical)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .lineLimit(1...3).textFieldStyle(.roundedBorder)
                            .disabled(client.isLoading)
                            .accessibilityIdentifier("x.query")
                        Text("Reads up to 10 recent search results allowed by the X API. It is a small snapshot, not all X activity or proof of a trend.")
                            .font(.callout).foregroundStyle(.secondary)
                    }

                    if client.currentlyConnected {
                        Button {
                            Task { await client.refresh(kind: source.kind, query: query) }
                        } label: {
                            Label(client.isLoading ? "Reading X…" : "Refresh from X", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.borderedProminent).tint(.cyan)
                        .disabled(client.isLoading)
                        .accessibilityIdentifier("x.refresh")
                    } else {
                        Button { client.connect() } label: {
                            Label("Connect X", systemImage: "person.crop.circle.badge.checkmark")
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.borderedProminent).tint(.cyan)
                        .disabled(!client.isConfigured || client.isLoading)
                        .accessibilityIdentifier("x.connect")
                    }

                    if client.isLoading { ProgressView().accessibilityLabel("X request in progress") }
                    Text(client.notice).font(.callout).accessibilityIdentifier("x.notice")
                    Text("Each refresh can consume your developer app's X API credits or paid read quota. There is no background polling. No post is published automatically.")
                        .font(.footnote).foregroundStyle(.secondary)

                    if let current = client.current {
                        snapshot(current)
                    }

                    if client.hasDeviceCredentials || client.currentlyConnected || client.isLoading {
                        Button(role: .destructive) {
                            Task { await client.disconnect() }
                        } label: { Text("Disconnect X and remove device credentials") }
                        .accessibilityIdentifier("x.disconnect")
                    }

                    Text("Sign-in uses X's system browser and read-only permissions. Tokens stay in this device's protected Keychain. The app keeps metric snapshots in memory; it does not send photos, LiDAR scans or game history to X.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Link("Manage X app access", destination: URL(string: "https://x.com/settings/connected_apps")!)
                        .font(.footnote)
                }
                .padding(24)
            }
            .background(Color(red: 0.025, green: 0.035, blue: 0.09))
            .navigationTitle("X currents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .onAppear { client.select(kind: source.kind, query: query) }
        .onChange(of: source) { _, _ in client.select(kind: source.kind, query: query) }
        .onChange(of: query) { _, _ in client.select(kind: source.kind, query: query) }
    }

    private func snapshot(_ current: ViralCurrent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(source == .personal ? "YOUR CURRENT" : "COMMUNITY CURRENT").font(.headline)
            Text("\(current.postCount) posts · sampled \(current.observedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                metric("Intensity · 0–1", value: current.intensity.formatted(.number.precision(.fractionLength(2))))
                metric("Conversation share", value: current.conversation.formatted(.percent.precision(.fractionLength(0))))
            }
            if let velocity = current.velocity {
                Text("Observed velocity: \(velocity.formatted(.number.precision(.fractionLength(2)))) weighted engagements/s · \(current.comparedPostCount) posts compared with the previous refresh.")
                    .font(.footnote)
            } else {
                Text("Velocity unavailable: this is the first comparable observation. Refresh later to measure change in the same posts.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let age = max(0, context.date.timeIntervalSince(current.observedAt))
                Text("Snapshot age: \(Int(age / 60)) min. This is recorded activity, not a live stream.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                onCurrent(current)
                dismiss()
            } label: {
                Label("Ride this current", systemImage: "water.waves")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent).tint(.mint)
            .disabled(client.isLoading || !client.currentlyConnected)
            .accessibilityIdentifier("x.ride")
            Text("The course uses this recorded snapshot. Refresh when you want newer activity.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(16).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("x.snapshot")
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit())
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
