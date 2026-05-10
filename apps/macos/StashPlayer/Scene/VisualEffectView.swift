import SwiftUI
import AppKit

/// Thin SwiftUI wrapper around `NSVisualEffectView` so the OSD bars and the
/// info popover share a single Infuse-style HUD vibrancy backdrop.
///
/// `.hudWindow` is what Apple ships their own video / fullscreen HUDs with —
/// it gives the dark, frosted-glass look that reads well over arbitrary
/// video frames without needing a custom tint. `.withinWindow` blends the
/// blur against in-window content rather than the desktop, which keeps
/// the panel feeling attached to the window rather than floating in space.
///
/// Setting `cornerRadius` rounds the actual NSVisualEffectView's backing
/// layer (with `.continuous` corner curve for the smooth Apple curvature),
/// so the blurred sample mask matches the visible edge — `.clipShape` on
/// the SwiftUI side leaves a subpixel halo at the corners.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    var state: NSVisualEffectView.State = .active
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = state
        v.isEmphasized = true
        if cornerRadius > 0 {
            v.wantsLayer = true
            v.layer?.cornerRadius = cornerRadius
            v.layer?.cornerCurve = .continuous
            v.layer?.masksToBounds = true
        }
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
        if cornerRadius > 0 {
            nsView.wantsLayer = true
            nsView.layer?.cornerRadius = cornerRadius
            nsView.layer?.cornerCurve = .continuous
            nsView.layer?.masksToBounds = true
        }
    }
}

/// Reusable "floating dark glass panel" backdrop — vibrancy + a substantial
/// black tint to darken `hudWindow`'s otherwise-greyish translucency over
/// arbitrary video frames + rounded corners + subtle 1pt white-stroke edge
/// + soft drop shadow. Apple's own HUDs (system volume / brightness OSD,
/// Now Playing) skip the stroke, but Infuse and most premium third-party
/// OSDs include it because it gives the glass a defined edge against
/// varying-brightness video.
struct OSDPanelBackground: View {
    var cornerRadius: CGFloat = 18

    var body: some View {
        ZStack {
            VisualEffectView(
                material: .hudWindow,
                blendingMode: .withinWindow,
                cornerRadius: cornerRadius
            )
            // hudWindow on its own reads as light-grey glass over bright
            // video frames. A 50%-black tint lands on the dark side of
            // Infuse's "black rounded rectangle" look while still letting
            // the underlying video bleed through at ~10% — feels alive,
            // not a flat black panel.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.5))
                .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 28, x: 0, y: 12)
    }
}
