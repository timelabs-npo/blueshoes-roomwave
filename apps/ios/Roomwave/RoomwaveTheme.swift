import SwiftUI

enum RoomwaveTheme {
    static let background = Color(red: 0.025, green: 0.045, blue: 0.075)
    static let panel = Color(red: 0.065, green: 0.095, blue: 0.14)
    static let accent = Color(red: 0.20, green: 0.94, blue: 0.87)
    static let violet = Color(red: 0.65, green: 0.47, blue: 1.0)
    static let warning = Color(red: 1.0, green: 0.70, blue: 0.30)
}

struct RoomwavePanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoomwaveTheme.panel, in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            }
    }
}

struct RoomwaveButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 24)
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .foregroundStyle(primary ? RoomwaveTheme.background : Color.white)
            .background(primary ? RoomwaveTheme.accent : RoomwaveTheme.panel,
                        in: RoundedRectangle(cornerRadius: 17))
            .overlay {
                RoundedRectangle(cornerRadius: 17)
                    .strokeBorder(primary ? .clear : .white.opacity(0.12), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

struct RoomwaveStat: View {
    let label: String
    let value: String
    var highlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(highlighted ? RoomwaveTheme.accent : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
