// Small original drawings distinguish PR and issue states without relying on
// colour. These are presentation choices, not stored observations: the GitHub
// owner supplies the meaning and freshness, and no view infers them from a URL.
import SwiftUI

enum GitHubSymbol: CaseIterable {
    case pullOpen, pullDraft, pullMerged, pullClosed, pullUnknown
    case issueOpen, issueClosed, issueUnknown

    var label: String {
        switch self {
        case .pullOpen: return "Open pull request"
        case .pullDraft: return "Draft pull request"
        case .pullMerged: return "Merged pull request"
        case .pullClosed: return "Closed pull request"
        case .pullUnknown: return "Pull request, state unknown"
        case .issueOpen: return "Open issue"
        case .issueClosed: return "Closed issue"
        case .issueUnknown: return "Issue, state unknown"
        }
    }

    var colour: Color {
        switch self {
        case .pullOpen, .issueOpen: return Palette.githubOpen
        case .pullMerged, .issueClosed: return Palette.githubFinished
        case .pullClosed: return Palette.danger
        default: return Palette.muted
        }
    }

    var isIssue: Bool {
        switch self {
        case .issueOpen, .issueClosed, .issueUnknown: return true
        default: return false
        }
    }
}

struct GitHubStateMark: View {
    let symbol: GitHubSymbol
    var old = false
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        GitHubStatePath(symbol: symbol)
            .stroke(old ? Palette.muted : symbol.colour,
                    style: StrokeStyle(lineWidth: metrics.length(Metrics.githubStroke),
                                       lineCap: .round, lineJoin: .round))
            .frame(width: metrics.length(Metrics.githubSymbol), height: metrics.length(Metrics.githubSymbol))
            .accessibilityLabel(symbol.label + (old ? ", older information" : ""))
    }
}

private struct GitHubStatePath: Shape {
    let symbol: GitHubSymbol

    func path(in rect: CGRect) -> Path {
        // Coordinates describe a 16-point drawing; interface density scales
        // the paths and stroke together, keeping the node holes legible.
        var path = Path()
        func node(_ x: CGFloat, _ y: CGFloat, radius: CGFloat = 1.65) {
            path.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        func line(_ points: [CGPoint]) {
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        if symbol.isIssue {
            path.addEllipse(in: CGRect(x: 1.75, y: 1.75, width: 12.5, height: 12.5))
            switch symbol {
            case .issueClosed:
                line([CGPoint(x: 4.5, y: 8), CGPoint(x: 7, y: 10.5), CGPoint(x: 11.5, y: 5.5)])
            case .issueOpen:
                node(8, 8, radius: 0.65)
            default:
                question(in: &path, x: 6, y: 4.5)
            }
        } else {
            node(3.5, 3)
            node(3.5, 13)
            line([CGPoint(x: 3.5, y: 4.7), CGPoint(x: 3.5, y: 11.3)])
            switch symbol {
            case .pullMerged:
                node(12.5, 13)
                path.move(to: CGPoint(x: 12.5, y: 11.3))
                path.addCurve(to: CGPoint(x: 5.2, y: 3), control1: CGPoint(x: 12.5, y: 5), control2: CGPoint(x: 5.2, y: 9))
            case .pullClosed:
                node(12.5, 13)
                line([CGPoint(x: 12.5, y: 11.3), CGPoint(x: 12.5, y: 8)])
                line([CGPoint(x: 10, y: 2), CGPoint(x: 14, y: 6)])
                line([CGPoint(x: 14, y: 2), CGPoint(x: 10, y: 6)])
            case .pullUnknown:
                question(in: &path, x: 10, y: 2)
                node(12, 13)
            case .pullDraft:
                node(12, 13)
                for y in [CGFloat(3), 6, 9] { node(12, y, radius: 0.4) }
            default:
                node(12.5, 13)
                path.move(to: CGPoint(x: 12.5, y: 11.3))
                path.addLine(to: CGPoint(x: 12.5, y: 5))
                path.addQuadCurve(to: CGPoint(x: 9, y: 3), control: CGPoint(x: 12.5, y: 3))
                line([CGPoint(x: 10.5, y: 1.5), CGPoint(x: 9, y: 3), CGPoint(x: 10.5, y: 4.5)])
            }
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 16, y: rect.height / 16)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }

    private func question(in path: inout Path, x: CGFloat, y: CGFloat) {
        path.move(to: CGPoint(x: x, y: y + 1))
        path.addCurve(to: CGPoint(x: x + 2, y: y + 4),
                      control1: CGPoint(x: x + 3, y: y - 2), control2: CGPoint(x: x + 6, y: y + 2))
        path.addLine(to: CGPoint(x: x + 2, y: y + 4.5))
        path.addEllipse(in: CGRect(x: x + 1.8, y: y + 6.3, width: 0.4, height: 0.4))
    }
}
