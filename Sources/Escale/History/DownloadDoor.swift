// Downloads keep one session-only door in the window's existing trailing action row.
// The popover observes Downloads directly; parked Spaces remain represented,
// while completed files stay in their existing history panel. The list is
// lazy and height-bounded. Progress and its observers end with each transfer;
// a failed one stays below the active ones, with Resume or Retry, until it is
// taken up again or removed. The one-off file flight is owned by the window
// and stops after arrival.
import SwiftUI

struct DownloadDoor: View {
    @ObservedObject var downloads: Downloads
    let history: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var showing = false

    var body: some View {
        Group {
            if downloads.hasStarted {
                Door(icon: "arrow.down", help: active ? "Active Downloads" : "Downloads") {
                    if listed { showing.toggle() } else { history() }
                }
                    .overlay {
                        if active {
                            Circle().stroke(Palette.wash, lineWidth: metrics.length(Metrics.downloadLine))
                                .frame(width: metrics.length(Metrics.downloadRing), height: metrics.length(Metrics.downloadRing))
                                .allowsHitTesting(false)
                            if let fraction = downloads.fraction {
                                Circle().trim(from: 0, to: fraction)
                                    .stroke(Palette.ink, style: StrokeStyle(lineWidth: metrics.length(Metrics.downloadLine), lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .frame(width: metrics.length(Metrics.downloadRing), height: metrics.length(Metrics.downloadRing))
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if downloads.transfers.count > 1 {
                            Text("\(downloads.transfers.count)")
                                .font(.system(size: metrics.length(Metrics.downloadBadge), weight: .medium))
                                .foregroundStyle(Palette.ink)
                                .padding(.horizontal, metrics.length(Metrics.downloadBadgeInset))
                                .background(Palette.ground, in: Capsule())
                                .allowsHitTesting(false)
                        }
                    }
                    .anchorPreference(key: DownloadFlightFrames.self, value: .bounds) {
                        DownloadFlightFrames(door: $0)
                    }
                    .onDisappear { showing = false }
                    .onChange(of: listed) { _, some in if !some { showing = false } }
                    .accessibilityLabel(active ? "Active Downloads" : "Downloads")
                    .accessibilityValue(status)
                    .popover(isPresented: $showing, arrowEdge: .bottom) { content }
            }
        }
    }

    private var active: Bool { !downloads.transfers.isEmpty }
    private var listed: Bool { active || !downloads.failures.isEmpty }

    private var status: String {
        let failed = downloads.failures.isEmpty ? "" : ", \(downloads.failures.count) failed"
        guard active else { return listed ? "No active download" + failed : "Download History" }
        let count = downloads.transfers.count
        if let fraction = downloads.fraction {
            return "\(count) active, \(Int((fraction * 100).rounded())) percent" + failed
        }
        return "\(count) active, total size unknown" + failed
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.toolGap)) {
            Text(active ? "Active Downloads" : "Downloads")
                .font(.system(size: metrics.length(Metrics.toolFont), weight: .medium))
            ScrollView {
                LazyVStack(spacing: metrics.length(Metrics.toolGap)) {
                    ForEach(downloads.transfers) { transfer in
                        VStack(alignment: .leading, spacing: metrics.length(Metrics.visualGap)) {
                            HStack {
                                Text(transfer.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                Door(icon: "xmark", help: "Cancel Download") { downloads.cancel(transfer.id) }
                                    .accessibilityLabel("Cancel \(transfer.name)")
                            }
                            if let fraction = transfer.fraction {
                                MigrationBar(fraction: fraction)
                                Text("\(Int((fraction * 100).rounded()))%")
                                    .foregroundStyle(Palette.muted)
                            } else {
                                HStack {
                                    MigrationSpinner()
                                    Text("Downloading · size unknown").foregroundStyle(Palette.muted)
                                }
                            }
                        }
                    }
                    ForEach(downloads.failures) { failure in
                        VStack(alignment: .leading, spacing: metrics.length(Metrics.visualGap)) {
                            HStack {
                                Text(failure.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                Door(icon: "xmark", help: "Remove") { downloads.remove(failure.id) }
                                    .accessibilityLabel("Remove \(failure.name)")
                            }
                            HStack {
                                Text("Failed").foregroundStyle(Palette.danger)
                                Spacer(minLength: 0)
                                if let action = failure.action {
                                    Pill(action) { downloads.retry(failure.id) }
                                        .accessibilityLabel("\(action) \(failure.name)")
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: min(metrics.length(Metrics.downloadListHeight),
                               CGFloat(downloads.transfers.count + downloads.failures.count) * metrics.length(Metrics.downloadRowHeight)))
            Button { showing = false; history() } label: {
                Label("Download History", systemImage: "clock")
            }
            .buttonStyle(MigrationButton(kind: .secondary))
        }
        .font(.system(size: metrics.length(Metrics.toolFont)))
        .foregroundStyle(Palette.ink)
        .padding(metrics.length(Metrics.toolInset))
        .frame(width: metrics.length(Metrics.downloadWidth))
        .popoverGround()
    }
}
