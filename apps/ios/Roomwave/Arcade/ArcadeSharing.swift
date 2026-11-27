import SwiftUI
import UIKit
import RoomwaveArcade

struct ArcadeSharePayload: Identifiable {
    let id = UUID()
    let image: UIImage
    let text: String
    let challenge: URL?
}

@MainActor
enum ArcadeSharing {
    static func make(result: SurfRunResult, title: String) throws -> ArcadeSharePayload {
        guard result.rulesVersion == SurfRules.standard.version else { throw ShareError.unsupported }
        var components = URLComponents()
        components.scheme = "roomwave"
        components.host = "challenge"
        components.queryItems = [URLQueryItem(name: "course", value: result.courseID),
                                 URLQueryItem(name: "rules", value: "3")]
        let url = ArcadeProfile.courseIDs.contains(result.courseID) ? components.url : nil
        let renderer = ImageRenderer(content: ArcadeResultCard(result: result, title: title)
            .frame(width: 540, height: 720).environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.uiImage else { throw ShareError.renderFailed }
        let medalText = result.medal == .none ? "No medal" : "\(result.medal.rawValue.capitalized) medal"
        let text = "TWITTER SURFER\n\(title) · \(result.score.formatted()) points\n"
            + "\(result.completed ? "Complete" : "Run ended") · \(medalText)\n"
            + "\(result.rings) rings · \(result.perfectLandings) perfect landings · ×\(result.bestCombo) best combo\n"
            + "Rules: \(result.rulesVersion)\n"
            + (url == nil ? "A locally created course; no shared challenge link in this beta." : "Play this course in Twitter Surfer.")
        return ArcadeSharePayload(image: image, text: text, challenge: url)
    }

    /// User-invoked editable web intent; it neither uploads a local card/video
    /// nor confirms that anything was posted.
    static func xComposer(result: SurfRunResult) -> URL? {
        guard result.rulesVersion == SurfRules.standard.version else { return nil }
        var components = URLComponents()
        components.scheme = "https"; components.host = "x.com"; components.path = "/intent/tweet"
        let text: String
        if ArcadeProfile.courseIDs.contains(result.courseID),
           let authored = SurfCatalog.course(id: result.courseID) {
            // The web link below opens the project, not the run. Give a player
            // with the beta installed an honest, copyable course/rules identity.
            text = "Can you beat \(result.score) on \(authored.title) in Roomwave? "
                + "In the beta, choose \(authored.title) (\(result.courseID), \(result.rulesVersion)). "
                + "Reply with your score and the first thing that felt unclear."
        } else {
            // Never share a photo/LiDAR/X-derived course title or identifier
            // with X. It is not a portable same-course challenge.
            text = "I scored \(result.score) on a custom Roomwave course. "
                + "This is a score recap, not a replay link."
        }
        components.queryItems = [URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "url", value: "https://github.com/timelabs-npo/blueshoes-roomwave")]
        return components.url
    }

    private enum ShareError: LocalizedError {
        case unsupported, renderFailed
        var errorDescription: String? {
            switch self {
            case .unsupported: return "This run cannot be shared with the current course rules."
            case .renderFailed: return "The score card could not be rendered. Please try again."
            }
        }
    }
}

struct ArcadeShareSheet: UIViewControllerRepresentable {
    let payload: ArcadeSharePayload

    func makeUIViewController(context: Context) -> UIActivityViewController {
        var items: [Any] = [payload.image, payload.text]
        if let challenge = payload.challenge { items.append(challenge) }
        let controller = UIActivityViewController(activityItems: items,
                                                  applicationActivities: nil)
        // The SwiftUI sheet supplies presentation; anchoring also supports iPad popovers.
        controller.popoverPresentationController?.sourceView = controller.view
        let bounds = controller.view.bounds
        controller.popoverPresentationController?.sourceRect = CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct ArcadeResultCard: View {
    let result: SurfRunResult
    let title: String
    private let teal = Color(red: 0.30, green: 0.96, blue: 0.85)
    private let gold = Color(red: 1, green: 0.79, blue: 0.40)

    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.045, blue: 0.09)
            LinearGradient(colors: [teal.opacity(0.12), .clear, gold.opacity(0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Path { path in
                path.move(to: CGPoint(x: -50, y: 610))
                path.addCurve(to: CGPoint(x: 600, y: 80), control1: CGPoint(x: 410, y: 590),
                              control2: CGPoint(x: 110, y: 210))
            }.stroke(teal.opacity(0.20), lineWidth: 44)
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("xsurf").font(.system(size: 33, weight: .black, design: .rounded)).tracking(4)
                    Text("RIDE THE CURRENT").font(.system(size: 12, weight: .medium)).foregroundStyle(teal)
                }
                Spacer()
                Text(title.uppercased()).font(.system(size: 18, weight: .bold)).tracking(3)
                Text(result.score.formatted()).font(.system(size: 82, weight: .bold, design: .rounded))
                    .monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
                Label(result.medal == .none ? "RUN RECORDED" : "\(result.medal.rawValue.uppercased()) MEDAL",
                      systemImage: result.medal == .none ? "waveform.path" : "seal.fill")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(gold)
                HStack(spacing: 32) {
                    fact("RINGS", "\(result.rings)")
                    fact("PERFECT", "\(result.perfectLandings)")
                    fact("COMBO", "×\(result.bestCombo)")
                }
                Rectangle().fill(teal.opacity(0.35)).frame(height: 1)
                Text(result.completed ? "CURRENT CONQUERED" : "THE NEXT RUN IS YOURS")
                    .font(.system(size: 13, weight: .semibold)).tracking(2)
                Text("\(result.courseID) · \(result.rulesVersion)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
            }.foregroundStyle(.white).padding(44)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 10, weight: .medium)).tracking(2).foregroundStyle(teal)
        }
    }
}
