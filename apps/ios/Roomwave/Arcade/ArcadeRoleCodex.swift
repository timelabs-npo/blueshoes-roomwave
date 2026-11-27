import SwiftUI
import UIKit

struct ArcadeRoleCodex: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Binding var selected: CrewRole

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Choose your crew")
                        .font(.system(.largeTitle, design: .rounded, weight: .black))
                    Text("Changes your rider outfit. Every crew races by the same rules.")
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
            .navigationTitle("Character")
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
        }
    }
}

enum CrewRole: String, Identifiable, CaseIterable {
    static let storageKey = "xs.rider.crew"

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
    var accent: Color { Color(uiColor: coatAccent) }

    var coatAccent: UIColor {
        switch self {
        case .duneRunners: UIColor(red: 1, green: 0.67, blue: 0.40, alpha: 1)
        case .basaltGuard: UIColor(red: 1, green: 0.42, blue: 0.54, alpha: 1)
        case .vectorOracles: UIColor(red: 0.48, green: 1, blue: 0.88, alpha: 1)
        case .echoWeavers: UIColor(red: 0.88, green: 0.59, blue: 1, alpha: 1)
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
}
