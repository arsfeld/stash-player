import SwiftUI
import AppKit

/// Native macOS glass backdrop for the OSD.
///
/// On macOS 26+ (Tahoe) we use the system Liquid Glass material via
/// `.glassEffect(_:in:)`. That is the only first-party API for the
/// translucent / refractive look the OSD wants — Apple ships it as the
/// material for floating navigation controls over media.
///
/// On macOS 14–25 we fall back to `NSVisualEffectView(.hudWindow,
/// .withinWindow)`, the same vibrancy material the system uses for the
/// volume / brightness HUDs. It is *not* Liquid Glass — it is the
/// pre-Tahoe equivalent, and we keep it only so the player still works
/// on Sonoma / Sequoia.

extension View {
    /// Native glass panel backdrop. On Tahoe we use
    /// `.glassEffect(.regular.tint(.black.opacity(0.35)), in: shape)`.
    /// `.regular` is the standard glass variant; the partial black
    /// tint blends just enough darkness into the material to keep
    /// white text/icons readable over bright video frames without
    /// flattening the refraction (a solid `.tint(.black)` kills the
    /// glass character). 0.35 puts us close to Apple's own media
    /// chrome density. Older macOS falls back to a tinted
    /// NSVisualEffectView with the same target opacity.
    @ViewBuilder
    func osdGlassPanel(cornerRadius: CGFloat = 18) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                .regular.tint(.black.opacity(0.35)),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self.background(LegacyOSDPanelBackground(cornerRadius: cornerRadius))
        }
    }

    /// Native glass pill backdrop (default capsule on Tahoe). Same
    /// black tint level as the panel so the two read as one control
    /// surface.
    @ViewBuilder
    func osdGlassPill() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(.black.opacity(0.35)))
        } else {
            self.background(LegacyOSDPillBackground())
        }
    }
}

/// Thin SwiftUI wrapper around `NSVisualEffectView`. Only referenced from
/// the legacy fallback path — Tahoe code does not touch it.
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

// MARK: - Pre-Tahoe fallbacks

private struct LegacyOSDPanelBackground: View {
    var cornerRadius: CGFloat = 18

    var body: some View {
        ZStack {
            VisualEffectView(
                material: .hudWindow,
                blendingMode: .withinWindow,
                cornerRadius: cornerRadius
            )
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.38))
                .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 28, x: 0, y: 12)
    }
}

private struct LegacyOSDPillBackground: View {
    var cornerRadius: CGFloat = 12

    var body: some View {
        ZStack {
            VisualEffectView(
                material: .hudWindow,
                blendingMode: .withinWindow,
                cornerRadius: cornerRadius
            )
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.32))
                .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 6)
    }
}
