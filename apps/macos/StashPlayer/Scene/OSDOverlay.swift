import SwiftUI
import AppKit

/// Infuse-style OSD overlay built on the native macOS Liquid Glass
/// material (`.glassEffect(_:in:)` on macOS 26+, NSVisualEffectView
/// fallback on macOS 14–25 via `.osdGlassPanel` / `.osdGlassPill`).
///
/// Layout:
///   - Top: floating glass "Close" pill (top-left, clear of traffic
///     lights) + scene title centered at the top with a text shadow,
///     no panel.
///   - Bottom: a single rounded glass panel with three rows —
///     scrubber, transport (volume left, transport buttons centered,
///     extras right), and time labels (elapsed left, -remaining right).
///   - The middle `Spacer` between top and bottom is
///     `allowsHitTesting(false)` so clicks on the bare video reach
///     `PlayerView`.
struct OSDOverlay: View {
    @ObservedObject var vm: OSDViewModel
    let scene: FfiScene
    let oCount: Int32
    let canGoPrev: Bool
    let canGoNext: Bool
    @Binding var autoplay: Bool
    @Binding var showInfo: Bool
    let onClose: () -> Void
    let onPrev: () -> Void
    let onNext: () -> Void
    let onToggleFullscreen: () -> Void
    let onBumpO: () -> Void
    let onResetO: () -> Void
    let onOpenInStash: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            OSDTopBar(
                title: scene.displayTitle,
                onClose: { vm.bumpReveal(); onClose() }
            )
            .ignoresSafeArea(.container, edges: .top)
            .opacity(vm.revealed ? 1 : 0)
            .offset(y: vm.revealed ? 0 : -8)
            .allowsHitTesting(vm.revealed)

            Spacer(minLength: 0)
                .allowsHitTesting(false)

            OSDBottomPanel(
                vm: vm,
                oCount: oCount,
                canGoPrev: canGoPrev,
                canGoNext: canGoNext,
                autoplay: $autoplay,
                showInfo: $showInfo,
                onPrev: { vm.bumpReveal(); onPrev() },
                onNext: { vm.bumpReveal(); onNext() },
                onToggleFullscreen: { vm.bumpReveal(); onToggleFullscreen() },
                onBumpO: { vm.bumpReveal(); onBumpO() },
                onResetO: { vm.bumpReveal(); onResetO() }
            )
            .fixedSize(horizontal: true, vertical: false)
            .padding(.bottom, 28)
            .opacity(vm.revealed ? 1 : 0)
            .offset(y: vm.revealed ? 0 : 12)
            .allowsHitTesting(vm.revealed)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: vm.revealed)
        .popover(isPresented: $showInfo, arrowEdge: .bottom) {
            InfoPopover(scene: scene, onOpenInStash: onOpenInStash)
        }
    }
}

// MARK: - Top bar

/// Floating top strip with a glass Close pill on the left and the scene
/// title centered. ZStack so the title centers on the window's full
/// width regardless of the pill's width.
private struct OSDTopBar: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        ZStack {
            HStack {
                OSDClosePill(action: onClose)
                    .padding(.leading, 78)
                Spacer(minLength: 0)
            }

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.85), radius: 4, x: 0, y: 1)
                .lineLimit(1)
                .padding(.horizontal, 200)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}

/// Glass pill with an X glyph + "Close" label. Uses the native capsule
/// glass on Tahoe and the legacy NSVisualEffectView pill on older macOS.
private struct OSDClosePill: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                Text("Close")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white.opacity(hovered ? 1 : 0.92))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .osdGlassPill()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close")
        .onHover { hovered = $0 }
    }
}

// MARK: - Bottom panel

private struct OSDBottomPanel: View {
    @ObservedObject var vm: OSDViewModel
    let oCount: Int32
    let canGoPrev: Bool
    let canGoNext: Bool
    @Binding var autoplay: Bool
    @Binding var showInfo: Bool
    let onPrev: () -> Void
    let onNext: () -> Void
    let onToggleFullscreen: () -> Void
    let onBumpO: () -> Void
    let onResetO: () -> Void

    /// Width of the slider tracks and time row. Drives the panel's
    /// overall width — the panel sizes to its content.
    private let trackWidth: CGFloat = 460

    var body: some View {
        VStack(spacing: 6) {
            scrubberRow
            transportRow
            timeRow
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .osdGlassPanel(cornerRadius: 18)
        .foregroundStyle(.white)
    }

    private var displayedSeconds: Double {
        vm.seekDraftSeconds ?? vm.currentSeconds
    }

    private var scrubberRow: some View {
        Slider(
            value: Binding(
                get: { displayedSeconds },
                set: { newValue in
                    if vm.seekDraftSeconds == nil {
                        vm.beginSeekDraft(newValue)
                    } else {
                        vm.updateSeekDraft(newValue)
                    }
                }
            ),
            in: 0...max(1, vm.durationSeconds),
            onEditingChanged: { editing in
                vm.bumpReveal()
                if !editing {
                    vm.commitSeekDraft()
                }
            }
        )
        .controlSize(.small)
        .tint(.white)
        .frame(width: trackWidth)
    }

    private var transportRow: some View {
        ZStack {
            // Left cluster — always-visible volume control.
            HStack(spacing: 0) {
                volumeCluster
                Spacer(minLength: 0)
            }

            // Right cluster — Stash extras + system extras anchored
            // trailing.
            HStack(spacing: 2) {
                Spacer(minLength: 0)
                oCounterCluster

                OSDIconButton(
                    systemName: autoplay ? "play.square.fill" : "play.square",
                    help: autoplay ? "Autoplay on — click to disable" : "Autoplay off — click to enable",
                    tinted: autoplay
                ) {
                    vm.bumpReveal()
                    autoplay.toggle()
                }

                OSDIconButton(systemName: "info.circle", help: "Scene details (i)") {
                    vm.bumpReveal()
                    showInfo.toggle()
                }

                OSDIconButton(
                    systemName: "arrow.up.left.and.arrow.down.right",
                    help: "Fullscreen (f)"
                ) {
                    onToggleFullscreen()
                }
            }

            // Center cluster — primary transport. Geometrically centered
            // by the ZStack regardless of left / right cluster widths.
            HStack(spacing: 2) {
                OSDIconButton(systemName: "backward.end.fill", help: "Previous scene") {
                    onPrev()
                }
                .disabled(!canGoPrev)
                .opacity(canGoPrev ? 1 : 0.35)

                OSDIconButton(systemName: "gobackward.10", help: "Back 10s (j)") {
                    vm.bumpReveal()
                    vm.skip(by: -10)
                }

                playPauseButton

                OSDIconButton(systemName: "goforward.10", help: "Forward 10s (l)") {
                    vm.bumpReveal()
                    vm.skip(by: 10)
                }

                OSDIconButton(systemName: "forward.end.fill", help: "Next scene") {
                    onNext()
                }
                .disabled(!canGoNext)
                .opacity(canGoNext ? 1 : 0.35)
            }
        }
        .frame(width: trackWidth)
    }

    private var timeRow: some View {
        HStack {
            Text(playhead(displayedSeconds))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.80))
            Spacer(minLength: 0)
            Text(remainingPlayhead(displayedSeconds, total: vm.durationSeconds))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.80))
        }
        .frame(width: trackWidth)
    }

    private var playPauseButton: some View {
        Button {
            vm.bumpReveal()
            vm.togglePlayPause()
        } label: {
            Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(vm.isPlaying ? "Pause (Space)" : "Play (Space)")
    }

    /// Always-visible volume: mute toggle + 60pt slider. No hover
    /// expand; matches the request to keep the control discoverable
    /// without a reveal interaction.
    private var volumeCluster: some View {
        HStack(spacing: 4) {
            Button {
                vm.bumpReveal()
                vm.toggleMute()
            } label: {
                Image(systemName: volumeIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(vm.isMuted ? "Unmute (m)" : "Mute (m)")

            Slider(
                value: Binding(
                    get: { Double(vm.isMuted ? 0 : vm.volume) },
                    set: { newValue in
                        vm.bumpReveal()
                        if vm.isMuted, newValue > 0 { vm.toggleMute() }
                        vm.setVolume(Float(newValue))
                    }
                ),
                in: 0...1
            )
            .controlSize(.mini)
            .frame(width: 64)
            .tint(.white)
        }
    }

    private var volumeIcon: String {
        if vm.isMuted || vm.volume <= 0.01 { return "speaker.slash.fill" }
        if vm.volume < 0.34 { return "speaker.wave.1.fill" }
        if vm.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private var oCounterCluster: some View {
        HStack(spacing: 2) {
            if oCount > 0 {
                Text("\(oCount)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.18), in: Capsule())
            }
            OSDIconButton(systemName: "drop.fill", help: "Increment O-counter") {
                onBumpO()
            }
            if oCount > 0 {
                OSDIconButton(systemName: "arrow.counterclockwise", help: "Reset O-counter") {
                    onResetO()
                }
            }
        }
    }
}

// MARK: - Shared icon button

/// Square icon button used throughout the OSD. SF Symbol with a gentle
/// hover background. Sized to pack tightly in the transport row.
private struct OSDIconButton: View {
    let systemName: String
    let help: String
    var size: CGFloat = 15
    var tinted: Bool = false
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tinted ? .white : .white.opacity(hovered ? 1 : 0.88))
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(.white.opacity(hovered ? 0.14 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovered = $0 }
    }
}

private func playhead(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    return formatDuration(seconds)
}

/// "-HH:MM:SS" / "-MM:SS" remaining-time label, Infuse-style.
private func remainingPlayhead(_ current: Double, total: Double) -> String {
    guard total.isFinite, total > 0, current.isFinite else { return "--:--" }
    let remaining = max(0, total - current)
    return "-" + formatDuration(remaining)
}
