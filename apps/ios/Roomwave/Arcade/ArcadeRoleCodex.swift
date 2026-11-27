import SwiftUI

struct ArcadeRoleCodex: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @State private var selected: CrewRole = .duneRunners

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Four ways to ride")
                        .font(.system(.largeTitle, design: .rounded, weight: .black))
                    Text("Crew concepts. Abilities shown here are not active in races.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(CrewRole.allCases) { role in
                            Button {
                                if reduceMotion { selected = role }
                                else { withAnimation(.easeInOut(duration: 0.18)) { selected = role } }
                            } label: {
                                Image(systemName: role.symbol)
                                    .font(.title3.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .background(role.accent.opacity(selected == role ? 0.23 : 0.07),
                                                in: RoundedRectangle(cornerRadius: 14))
                                    .foregroundStyle(role.accent)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(role.title)
                            .accessibilityAddTraits(selected == role ? .isSelected : [])
                            .accessibilityIdentifier("arcade.role.\(role.rawValue)")
                        }
                    }
                    portrait(selected).id(selected)
                }.padding()
            }
            .background(Color(red: 0.04, green: 0.05, blue: 0.10))
            .navigationTitle("Crews")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func portrait(_ role: CrewRole) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image("Role-\(role.rawValue)")
                .resizable().scaledToFit().frame(maxWidth: 480)
                .clipShape(.rect(cornerRadius: 18))
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity)
            Text(role.title).font(.title2.weight(.heavy)).foregroundStyle(role.accent)
                .accessibilityIdentifier("arcade.role-title")
            Text(role.pitch).font(.body)
            Text(role.ability).font(.callout.weight(.semibold)).foregroundStyle(role.accent)
        }
    }
}

private enum CrewRole: String, Identifiable, CaseIterable {
    case duneRunners = "dune-runners"
    case basaltGuard = "basalt-guard"
    case vectorOracles = "vector-oracles"
    case echoWeavers = "echo-weavers"

    var id: Self { self }
    var title: String {
        switch self {
        case .duneRunners: "Dune Runners"
        case .basaltGuard: "Basalt Guard"
        case .vectorOracles: "Vector Oracles"
        case .echoWeavers: "Echo Weavers"
        }
    }
    var symbol: String {
        switch self {
        case .duneRunners: "wind"
        case .basaltGuard: "shield.lefthalf.filled"
        case .vectorOracles: "viewfinder"
        case .echoWeavers: "waveform.path"
        }
    }
    var accent: Color {
        switch self {
        case .duneRunners: Color(red: 1, green: 0.67, blue: 0.40)
        case .basaltGuard: Color(red: 1, green: 0.42, blue: 0.54)
        case .vectorOracles: Color(red: 0.48, green: 1, blue: 0.88)
        case .echoWeavers: Color(red: 0.88, green: 0.59, blue: 1)
        }
    }
    var pitch: String {
        switch self {
        case .duneRunners: "Sand navigators who find speed where the surface gives way."
        case .basaltGuard: "Heavy outriders who keep their line when everyone else breaks."
        case .vectorOracles: "Plotters who read the shape of the next gate before it comes into view."
        case .echoWeavers: "Rig modders who trade a favorite trick for a second chance."
        }
    }
    var ability: String {
        switch self {
        case .duneRunners: "Slipstream · one sustained burst after a clean landing."
        case .basaltGuard: "Brace · absorb one collision, at a speed cost."
        case .vectorOracles: "Foresight · read the next two gates in advance."
        case .echoWeavers: "Rewire · swap one optional perk before the race."
        }
    }
}
