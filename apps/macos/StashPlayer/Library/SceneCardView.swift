import SwiftUI

struct SceneCardView: View {
    let scene: FfiScene
    @EnvironmentObject var app: AppState
    @State private var thumb: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(.tertiary.opacity(0.4))
                if let thumb {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(scene.displayTitle)
                    .lineLimit(1)
                    .font(.callout.weight(.semibold))
                if !metaLine.isEmpty {
                    Text(metaLine)
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await loadThumb() }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let studio = scene.studio?.name { parts.append(studio) }
        if let dur = scene.files.first?.duration { parts.append(formatDuration(dur)) }
        return parts.joined(separator: " · ")
    }

    private func loadThumb() async {
        guard let url = scene.paths.screenshot ?? scene.paths.preview else { return }
        do {
            thumb = try await app.fetchThumbnail(url: url)
        } catch {
            // Best-effort.
        }
    }
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%d:%02d", m, s)
}
