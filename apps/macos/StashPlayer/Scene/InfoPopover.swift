import SwiftUI
import AppKit

/// Performer chips + details + file metadata + Open-in-Stash, presented as
/// a popover from the OSD's ⓘ button. This is what the (now-removed)
/// bottom metadata panel used to surface — we just summon it on demand
/// instead of permanently chewing window real estate.
struct InfoPopover: View {
    let scene: FfiScene
    let onOpenInStash: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !scene.performers.isEmpty {
                    performerChips
                }
                if let details = scene.details, !details.isEmpty {
                    Text(details)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if scene.files.first != nil {
                    fileInfo
                }
            }
            .padding(20)
        }
        .frame(width: 420, height: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(scene.displayTitle)
                .font(.title2.weight(.semibold))
                .lineLimit(2)
            if !subtitleLine.isEmpty {
                Text(subtitleLine)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            Button {
                onOpenInStash()
            } label: {
                Label("Open in Stash", systemImage: "safari")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 4)
        }
    }

    private var subtitleLine: String {
        var parts: [String] = []
        if let studio = scene.studio?.name { parts.append(studio) }
        if let date = scene.date { parts.append(date) }
        if let dur = scene.files.first?.duration { parts.append(formatDuration(dur)) }
        if let f = scene.files.first, let w = f.width, let h = f.height {
            parts.append("\(w)×\(h)")
        }
        if let r = scene.rating100, r > 0 {
            parts.append(String(format: "★ %.1f", Double(r) / 20.0))
        }
        if let played = scene.playCount, played > 0 {
            parts.append("Played \(played)")
        }
        return parts.joined(separator: " · ")
    }

    private var performerChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Performers")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(scene.performers, id: \.id) { performer in
                    HStack(spacing: 6) {
                        Image(systemName: "person.crop.circle.fill")
                            .foregroundStyle(.secondary)
                        Text(performer.name).font(.callout)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
                }
            }
        }
    }

    private var fileInfo: some View {
        let f = scene.files.first
        return VStack(alignment: .leading, spacing: 6) {
            Text("File")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                if let codec = f?.videoCodec { row("Codec", codec) }
                if let w = f?.width, let h = f?.height {
                    row("Resolution", "\(w)×\(h)")
                }
                if let fps = f?.frameRate {
                    row("Frame rate", String(format: "%.2f fps", fps))
                }
                if let dur = f?.duration {
                    row("Duration", formatDuration(dur))
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}

/// Minimal flow layout for performer chips — wraps to a new row when
/// horizontal space runs out. Saves us a third-party dep.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x)
        }
        return CGSize(width: max(0, maxX - spacing), height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// `formatDuration(_:)` lives in SceneCardView.swift — reused here.
