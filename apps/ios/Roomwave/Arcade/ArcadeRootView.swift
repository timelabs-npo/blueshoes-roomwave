import SwiftUI
import UIKit
import RoomwaveArcade

@MainActor
struct ArcadeRootView: View {
    @ObservedObject var session: ArcadeSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReducedMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.openURL) private var openURL
    @State private var characterPresented = false
    @AppStorage(CrewRole.storageKey) private var selectedCrew = CrewRole.duneRunners
    @State private var settingsPresented = false
    @State private var creatorPresented = false
    @State private var socialPresented = false
    @StateObject private var social = XActivityClient()
    @State private var sharePayload: ArcadeSharePayload?
    @State private var shareError: String?
    @State private var draftToCopy: String?
    @State private var requestedExtra: Extra?
    @AccessibilityFocusState(for: .voiceOver) private var resultTitleFocused: Bool
    private enum Extra { case creator, xCurrents }
    private let ink = Color(red: 0.025, green: 0.04, blue: 0.08)
    private let teal = Color(red: 0.30, green: 0.96, blue: 0.85)
    private let gold = Color(red: 1, green: 0.79, blue: 0.40)

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 500
            ZStack {
                ink.ignoresSafeArea()
                ArcadeSceneHost(scene: session.scene).ignoresSafeArea().accessibilityHidden(true)
                LinearGradient(colors: [.black.opacity(0.48), .clear, .black.opacity(0.7)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea().allowsHitTesting(false)
                if session.screen == .playing, session.errorMessage == nil {
                    ArcadeTouchSurface(changed: { session.setPressed($0) }, cancelled: { session.cancelTouch() })
                        .ignoresSafeArea()
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Surf control")
                        .accessibilityHint("Hold to charge, release to launch. Hold in the air to dive, then release before landing.")
                        .accessibilityIdentifier("arcade.surf")
                        .accessibilityAction(named: "Hold to charge or dive") { session.setPressed(true) }
                        .accessibilityAction(named: "Release to launch") { session.setPressed(false) }
                }
                switch session.screen {
                case .home: home(compact: compact)
                case .playing: playing(compact: compact)
                case .paused: paused(compact: compact)
                case .results: results(compact: compact)
                }
                if session.isLoading {
                    ZStack {
                        ink.opacity(0.75).ignoresSafeArea()
                        ProgressView("PREPARING THE CURRENT").tint(teal)
                            .font(.caption.weight(.semibold)).tracking(2)
                    }.accessibilityAddTraits(.isModal)
                }
                if let error = session.errorMessage {
                    errorOverlay(error)
                }
            }
            .foregroundStyle(.white)
            .fontDesign(.rounded)
            .tint(teal)
        }
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(session.screen == .playing ? .hidden : .automatic)
        .task {
            session.setActive(scenePhase == .active)
            session.setSystemReducedMotion(systemReducedMotion)
            session.scene.setCrew(selectedCrew)
            await session.bootstrap()
        }
        .onOpenURL { if $0.scheme?.lowercased() == "roomwave" { session.handle(url: $0) } }
        .onChange(of: scenePhase) { _, phase in
            session.setActive(phase == .active && !creatorPresented && !socialPresented)
        }
        .onChange(of: systemReducedMotion) { _, value in session.setSystemReducedMotion(value) }
        .onDisappear { session.pause() }
        .onChange(of: selectedCrew) { _, role in session.scene.setCrew(role) }
        .sheet(isPresented: $characterPresented) { ArcadeRoleCodex(selected: $selectedCrew) }
        .sheet(isPresented: $settingsPresented, onDismiss: showRequestedExtra) { settings }
        .sheet(isPresented: $creatorPresented, onDismiss: { session.setActive(scenePhase == .active) }) {
            ArcadeCreatorView { session.useInspiredCourse($0) }
        }
        .sheet(isPresented: $socialPresented, onDismiss: { session.setActive(scenePhase == .active) }) {
            XActivityView(client: social) { current in
                session.useViralCurrent(current)
                socialPresented = false
            }
        }
        .sheet(item: $sharePayload) { ArcadeShareSheet(payload: $0) }
        .alert("Could not share", isPresented: Binding(get: { shareError != nil },
            set: { if !$0 { shareError = nil } })) {
            if let draft = draftToCopy {
                Button("Copy post text") {
                    UIPasteboard.general.string = draft
                    draftToCopy = nil
                    shareError = nil
                }
            }
            Button("OK", role: .cancel) {
                draftToCopy = nil
                shareError = nil
            }
        } message: { Text(shareError ?? "") }
    }

    private func home(compact: Bool) -> some View {
        VStack(spacing: compact ? 12 : 22) {
            HStack(alignment: .top) {
                brand(compact: compact)
                Spacer()
                Button { settingsPresented = true } label: {
                    Image(systemName: "slider.horizontal.3").font(.title3)
                        .frame(width: 48, height: 48)
                }.accessibilityLabel("Sound, haptics and motion settings")
                    .accessibilityIdentifier("arcade.settings")
            }
            Spacer(minLength: compact ? 10 : 70)
            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    courseArrow("chevron.left", offset: -1)
                    VStack(spacing: 8) {
                        Text(session.title.uppercased()).font(.system(size: compact ? 22 : 27, weight: .bold))
                            .tracking(2).lineLimit(1).minimumScaleFactor(0.65)
                        Text(session.subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center).lineLimit(2)
                    }.frame(maxWidth: .infinity)
                    courseArrow("chevron.right", offset: 1)
                }
                HStack(spacing: 8) {
                    ForEach(session.availableCourseIDs, id: \.self) { id in
                        Capsule().fill(id == session.selectedID ? teal : .white.opacity(0.25))
                            .frame(width: id == session.selectedID ? 24 : 6, height: 4)
                    }
                }.accessibilityLabel(ArcadeProfile.courseIDs.contains(session.selectedID)
                    ? "Course \((session.availableCourseIDs.firstIndex(of: session.selectedID) ?? 0) + 1) of \(session.availableCourseIDs.count)"
                    : "Locally created course")
                if let best = session.selectedBest {
                    Text("BEST \(best.score.formatted())  ·  \(best.medal.rawValue.uppercased())")
                        .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(gold)
                }
            }
            primary("PLAY", symbol: "play.fill") { session.play() }
                .accessibilityIdentifier("arcade.play")
                .disabled(session.isLoading || session.course == nil)
            Button { characterPresented = true } label: {
                VStack(spacing: 2) {
                    Label {
                        Text("Character")
                    } icon: {
                        Image("xsurf-character-glyph").renderingMode(.template).resizable()
                            .scaledToFit().frame(width: 20, height: 20)
                    }
                        .font(.subheadline.weight(.semibold))
                    Text(selectedCrew.title).font(.caption).foregroundStyle(selectedCrew.accent)
                }.frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Character")
            .accessibilityValue(selectedCrew.title)
            .accessibilityIdentifier("arcade.crews")
            if !compact {
                Text("HOLD TO CHARGE  ·  RELEASE TO SOAR")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.white.opacity(0.72))
            }
            notice
        }.padding(.horizontal, 24).padding(.vertical, compact ? 8 : 20)
            .frame(maxWidth: 680).frame(maxWidth: .infinity)
    }

    private func playing(compact: Bool) -> some View {
        ZStack(alignment: .top) {
            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.hud.score.formatted()).font(.system(size: compact ? 28 : 40, weight: .bold))
                            .monospacedDigit().contentTransition(.identity)
                            .accessibilityLabel("Score \(session.hud.score)")
                        Text("COMBO \(session.hud.combo)").font(.caption.weight(.bold)).foregroundStyle(teal)
                            .accessibilityLabel("Combo \(session.hud.combo)")
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 7) {
                        HStack(spacing: 4) {
                            ForEach(0..<3) { index in
                                Image(systemName: index < session.hud.shields ? "shield.fill" : "shield")
                                    .foregroundStyle(index < session.hud.shields ? teal : .white.opacity(0.35))
                            }
                        }.accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(session.hud.shields) shields remaining")
                        Text("\(session.hud.speed) SPEED").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    }.padding(.trailing, 60)
                }
                ProgressView(value: session.hud.progress).tint(teal).scaleEffect(x: 1, y: 0.6)
                    .accessibilityLabel("Course progress").accessibilityValue("\(Int(session.hud.progress * 100)) percent")
                if !session.hud.callout.isEmpty {
                    Text(session.hud.callout).font(.system(size: 13, weight: .bold)).tracking(2)
                        .foregroundStyle(gold).id(session.hud.calloutID)
                        .padding(.vertical, 8)
                }
                Spacer()
                if let tutorial = session.tutorial {
                    Text(tutorial).font(.system(size: 11, weight: .bold)).tracking(1.8)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(ink.opacity(0.75), in: Capsule())
                }
                if let cue = session.masteryCue {
                    Text(cue).font(.caption.weight(.heavy)).tracking(2)
                        .foregroundStyle(gold)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(ink.opacity(0.85), in: Capsule())
                        .accessibilityIdentifier("arcade.mastery-cue")
                }
                if session.hud.charge > 0.02, !session.hud.airborne {
                    ProgressView(value: min(1, max(0, session.hud.charge))).tint(gold)
                        .frame(width: 120).accessibilityLabel("Launch charge")
                }
            }.allowsHitTesting(false)
            HStack {
                Spacer()
                Button { session.pause() } label: {
                    Image(systemName: "pause.fill").font(.title3).frame(width: 48, height: 48)
                        .background(ink.opacity(0.6), in: Circle())
                }.accessibilityLabel("Pause run").accessibilityIdentifier("arcade.pause")
            }
        }.padding(.horizontal, 22).padding(.vertical, 12)
    }

    private func paused(compact: Bool) -> some View {
        ZStack {
            ink.opacity(0.72).ignoresSafeArea()
            VStack(spacing: compact ? 12 : 22) {
                Text("TAKE A BREATH").font(.system(size: 26, weight: .bold)).tracking(2)
                Text("Your current is waiting.").font(.subheadline).foregroundStyle(.white.opacity(0.7))
                primary("RESUME", symbol: "play.fill") { session.resume() }
                    .accessibilityIdentifier("arcade.resume")
                HStack(spacing: 24) {
                    secondary("Restart", symbol: "arrow.clockwise") { session.play() }
                    secondary("Home", symbol: "house") { session.home() }
                        .accessibilityIdentifier("arcade.home")
                }
                if !session.preferences.tutorialSeen {
                    Button("Hide control tips") { session.dismissTutorial() }
                        .font(.footnote).frame(minHeight: 44)
                        .accessibilityIdentifier("arcade.dismiss-tutorial")
                }
            }.padding(28).frame(maxWidth: 440)
        }
    }

    private func results(compact: Bool) -> some View {
        ZStack {
            ink.opacity(0.82).ignoresSafeArea()
            if let result = session.result {
                ArcadeFinishHorizon(completed: result.completed,
                                    reduceMotion: systemReducedMotion || session.reducedMotion)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                ScrollView {
                    VStack(spacing: compact ? 12 : 20) {
                        if compact && !typeSize.isAccessibilitySize {
                            HStack(spacing: 30) {
                                resultSummary(result, compact: true)
                                resultActions(result)
                            }
                        } else {
                            resultSummary(result, compact: false)
                            resultActions(result)
                            notice
                        }
                        resultCredits
                    }
                    .padding(compact ? 16 : 24)
                    .frame(maxWidth: compact ? 780 : 500)
                    .frame(maxWidth: .infinity)
                }.defaultScrollAnchor(.center, for: .alignment)
            }
        }
    }

    private var resultCredits: some View {
        VStack(spacing: 3) {
            Text("CREDITS").font(.caption2.weight(.bold)).tracking(2)
                .accessibilityIdentifier("arcade.run-credits")
            Text("Roomwave team · original art, animation & sound")
            if let track = session.raceTrackCredit {
                Link("\(track.title) · MintoDog · CC0", destination: track.source)
                    .foregroundStyle(teal)
                    .frame(minHeight: 44)
            }
            Link("Quaternius · rider base & rig (CC0)",
                 destination: URL(string: "https://quaternius.com/packs/universalbasecharacters.html")!)
                .foregroundStyle(teal)
                .frame(minHeight: 44)
            Link("Tabler Icons · Paweł Kuna · MIT",
                 destination: URL(string: "https://github.com/tabler/tabler-icons")!)
                .foregroundStyle(teal)
                .frame(minHeight: 44)
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.84))
        .multilineTextAlignment(.center)
    }

    private func resultSummary(_ result: SurfRunResult, compact: Bool) -> some View {
        VStack(spacing: compact ? 10 : 18) {
            Text(result.completed ? "LINE COMPLETE" : "RUN ENDED")
                .font(.system(size: compact ? 12 : 16, weight: .bold)).tracking(2).foregroundStyle(teal)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($resultTitleFocused)
                .onAppear { resultTitleFocused = true }
                .onDisappear { resultTitleFocused = false }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(result.score.formatted()).font(.system(size: compact ? 48 : 68, weight: .bold))
                    .monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
                if result.medal != .none {
                    VStack(spacing: 3) {
                        Image(systemName: "seal.fill").font(.title2)
                        Text(result.medal.rawValue.uppercased()).font(.system(size: 9, weight: .bold))
                    }.foregroundStyle(gold).accessibilityLabel("\(result.medal.rawValue) medal")
                }
            }
            if let explanation = session.resultExplanation {
                Text(explanation).font(.caption).foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("arcade.result-cause")
            }
            Text(bestComparison(result.score)).font(.caption.weight(.semibold)).foregroundStyle(gold)
            HStack(spacing: compact ? 18 : 28) {
                statistic("RINGS", value: "\(result.rings)")
                statistic("PERFECT", value: "\(result.perfectLandings)")
                statistic("BEST COMBO", value: "\(result.bestCombo)")
            }
        }
    }

    private func resultActions(_ result: SurfRunResult) -> some View {
        VStack(spacing: 16) {
            Text(session.title.uppercased()).font(.caption.weight(.medium)).tracking(2)
                .foregroundStyle(.white.opacity(0.7))
            primary("RETRY", symbol: "arrow.clockwise") { session.play() }
                .accessibilityIdentifier("arcade.retry")
            Button {
                draftToCopy = nil
                guard let url = ArcadeSharing.xComposer(result: result) else {
                    shareError = "Could not create an X draft. You can still use More sharing options."
                    return
                }
                openURL(url) { accepted in
                    if !accepted {
                        draftToCopy = ArcadeSharing.xDraft(result: result)
                        shareError = "Could not open X. Copy the post text or use More sharing options."
                    }
                }
            } label: {
                Label {
                    Text("Share on X")
                } icon: {
                    Image("xsurf-share-glyph").renderingMode(.template).resizable()
                        .scaledToFit().frame(width: 20, height: 20)
                }
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                    .padding(.horizontal, 14)
                    .background(ink.opacity(0.72), in: Capsule())
                    .overlay { Capsule().stroke(teal.opacity(0.7), lineWidth: 1) }
            }
            .buttonStyle(.plain).frame(maxWidth: 360)
            .accessibilityIdentifier("arcade.share-x")
            .accessibilityHint("Opens an editable post. Nothing is published automatically.")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { courseAndShareActions(result) }
                VStack(spacing: 0) { courseAndShareActions(result) }
            }
        }
    }

    @ViewBuilder
    private func courseAndShareActions(_ result: SurfRunResult) -> some View {
        secondary("Courses", symbol: "water.waves") { session.home() }
        secondary("More sharing options", symbol: "ellipsis") {
            draftToCopy = nil
            do { sharePayload = try ArcadeSharing.make(result: result, title: session.title) }
            catch { shareError = error.localizedDescription }
        }
    }

    private func showRequestedExtra() {
        guard let extra = requestedExtra else { return }
        requestedExtra = nil
        session.setActive(false)
        switch extra {
        case .creator: creatorPresented = true
        case .xCurrents: socialPresented = true
        }
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Toggle("Sound", isOn: preference(\.soundEnabled))
                Toggle("Haptics", isOn: preference(\.hapticsEnabled))
                Toggle("Reduce motion", isOn: preference(\.reducedMotion))
                if systemReducedMotion {
                    Text("System Reduce Motion is enabled.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Explore") {
                    Button {
                        requestedExtra = .creator
                        settingsPresented = false
                    } label: {
                        Label("Create a current", systemImage: "sparkles.rectangle.stack")
                    }.accessibilityIdentifier("arcade.creator")
                    Button {
                        requestedExtra = .xCurrents
                        settingsPresented = false
                    } label: {
                        Label("X currents", systemImage: "waveform.path")
                    }.accessibilityIdentifier("arcade.x-currents")
                }
                Text("Your progress and last replay stay in this app’s private storage. Sharing sends only the score card, run facts and a course link you choose to share.")
                    .font(.footnote).foregroundStyle(.secondary)
                Link("Privacy policy", destination: URL(string: "https://github.com/timelabs-npo/blueshoes-roomwave/blob/main/docs/PRIVACY.md")!)
            }
            .navigationTitle("Preferences").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settingsPresented = false } } }
        }.presentationDetents([.large]).preferredColorScheme(.dark)
    }

    private func preference(_ keyPath: WritableKeyPath<ArcadePreferences, Bool>) -> Binding<Bool> {
        Binding(get: { session.preferences[keyPath: keyPath] }, set: { value in
            var preferences = session.preferences
            preferences[keyPath: keyPath] = value
            session.updatePreferences(preferences)
        })
    }

    @ViewBuilder private var notice: some View {
        if let message = session.statusMessage {
            HStack(alignment: .top, spacing: 8) {
                Text(message).font(.caption).foregroundStyle(.white.opacity(0.8))
                Button { session.dismissNotice() } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }.accessibilityLabel("Dismiss notice")
            }.frame(maxWidth: 460)
        }
    }

    private func brand(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("xsurf").font(.system(size: compact ? 23 : 31, weight: .black)).tracking(2)
                .foregroundStyle(LinearGradient(colors: [.white, teal], startPoint: .topLeading, endPoint: .bottomTrailing))
                .minimumScaleFactor(0.6).lineLimit(1)
            Text("RIDE THE SOCIAL CURRENT.").font(.system(size: 10, weight: .medium)).foregroundStyle(teal)
        }.accessibilityElement(children: .combine)
    }

    private func courseArrow(_ symbol: String, offset: Int) -> some View {
        Button { session.selectCourse(offset: offset) } label: {
            Image(systemName: symbol).font(.title3).frame(width: 44, height: 52)
        }.accessibilityLabel(offset < 0 ? "Previous course" : "Next course")
            .accessibilityIdentifier(offset < 0 ? "arcade.previous-course" : "arcade.next-course")
            .disabled(session.isLoading)
    }

    private func primary(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 17, weight: .bold)).tracking(2)
                .frame(maxWidth: .infinity).frame(minHeight: 56)
                .background(teal, in: Capsule()).foregroundStyle(ink)
        }.buttonStyle(.plain).frame(maxWidth: 360)
    }

    private func secondary(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).frame(minHeight: 48)
        }.buttonStyle(.plain)
    }

    private func statistic(_ title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(title).font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(teal)
        }.accessibilityElement(children: .combine)
    }

    private func bestComparison(_ score: Int) -> String {
        guard ArcadeProfile.courseIDs.contains(session.selectedID) else { return "LOCAL CREATED COURSE" }
        guard let previous = session.previousBest else { return "FIRST RUN · PERSONAL BEST" }
        let delta = score - previous
        if delta > 0 { return "NEW BEST · +\(delta.formatted())" }
        if delta == 0 { return "PERSONAL BEST MATCHED" }
        return "\(delta.formatted()) FROM BEST \(previous.formatted())"
    }

    private func errorOverlay(_ message: String) -> some View {
        ZStack {
            ink.opacity(0.95).ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: "water.waves.slash").font(.largeTitle).foregroundStyle(gold)
                Text("CURRENT INTERRUPTED").font(.headline).tracking(2)
                Text(message).font(.subheadline).multilineTextAlignment(.center)
                primary("TRY AGAIN", symbol: "arrow.clockwise") { session.retryLoad() }
            }.padding(32).frame(maxWidth: 480)
        }.accessibilityAddTraits(.isModal)
    }
}

@MainActor
private struct ArcadeSceneHost: UIViewRepresentable {
    let scene: ArcadeSceneController
    func makeUIView(context: Context) -> UIView { scene.view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

@MainActor
private struct ArcadeTouchSurface: UIViewRepresentable {
    let changed: (Bool) -> Void
    let cancelled: () -> Void
    func makeUIView(context: Context) -> ArcadeTouchView {
        let view = ArcadeTouchView()
        view.changed = changed
        view.cancelled = cancelled
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        return view
    }
    func updateUIView(_ uiView: ArcadeTouchView, context: Context) {
        uiView.changed = changed
        uiView.cancelled = cancelled
    }
    static func dismantleUIView(_ uiView: ArcadeTouchView, coordinator: ()) { uiView.cancel() }
}

@MainActor
private final class ArcadeTouchView: UIView {
    var changed: ((Bool) -> Void)?
    var cancelled: (() -> Void)?
    private var heldTouches: Set<UITouch> = []
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        heldTouches.formUnion(touches); changed?(true)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        heldTouches.subtract(touches); changed?(!heldTouches.isEmpty)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancel() }
    override func didMoveToWindow() { if window == nil { cancel() } }
    func cancel() { heldTouches.removeAll(keepingCapacity: true); cancelled?() }
}

private struct ArcadeFinishHorizon: View {
    let completed: Bool
    let reduceMotion: Bool
    @State private var settled = false

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let bronze = Color(red: 0.76, green: 0.36, blue: 0.23)
            let accent = completed
                ? Color(red: 1, green: 0.75, blue: 0.39)
                : Color(red: 0.39, green: 0.68, blue: 0.68)
            let horizon = CGPoint(x: w * 0.76, y: h * 0.26)
            let r = min(w, h) * 0.24
            let glow = Path(ellipseIn: CGRect(x: horizon.x - r, y: horizon.y - r,
                                              width: 2 * r, height: 2 * r))
            context.fill(glow, with: .radialGradient(
                Gradient(colors: [accent.opacity(0.54), accent.opacity(0)]),
                center: horizon, startRadius: 0, endRadius: r))
            for i in 0..<3 {
                let y = h * (0.63 + CGFloat(i) * 0.11)
                var dune = Path()
                dune.move(to: CGPoint(x: -10, y: y))
                dune.addCurve(to: CGPoint(x: w + 10, y: y - h * 0.11),
                              control1: CGPoint(x: w * 0.33, y: y + h * 0.25),
                              control2: CGPoint(x: w * 0.67, y: y - h * 0.37))
                context.stroke(dune, with: .linearGradient(
                    Gradient(colors: [.clear, bronze.opacity(0.52), accent.opacity(0.64), .clear]),
                    startPoint: .zero, endPoint: CGPoint(x: w, y: 0)), lineWidth: i == 0 ? 2 : 1)
            }
        }
        .scaleEffect(reduceMotion || settled ? 1 : 1.045)
        .opacity(reduceMotion || settled ? 1 : 0)
        .onAppear {
            if reduceMotion { settled = true }
            else { withAnimation(.easeOut(duration: 0.55)) { settled = true } }
        }
    }
}
