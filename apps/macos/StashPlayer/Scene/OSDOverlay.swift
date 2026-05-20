import SwiftUI
import AppKit

/// Infuse-style OSD overlay — two floating dark-glass panels with rounded
/// corners, soft drop shadows, and a subtle 1pt edge stroke. Top panel
/// carries metadata (chevron-back + title + subtitle); bottom panel
/// carries the unified scrubber + transport + Stash extras.
///
/// Layout rules:
///   - Both panels float with margins (top: 40pt to clear traffic lights,
///     bottom: 24pt, sides: 24pt). They are never edge-to-edge.
///   - Corner radius 18pt — matches Apple's system HUD constant.
///   - The `Spacer` between panels is `allowsHitTesting(false)` so clicks
///     on the bare video reach `PlayerView` (single-click → play/pause,
///     double-click → fullscreen, drag → window move).
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
            // Top header: always-visible row that sits inline with the
            // window's traffic lights. No background — the back button +
            // title float directly on the video with text shadows for
            // readability. `.ignoresSafeArea(.container, edges: .top)` so
            // the row sits flush with the window edge instead of being
            // pushed below the (transparent) title bar.
            OSDTopHeader(
                title: scene.displayTitle,
                subtitle: subtitleLine,
                onClose: onClose
            )
            .frame(maxWidth: .infinity)
            .ignoresSafeArea(.container, edges: .top)

            Spacer(minLength: 0)
                .allowsHitTesting(false)

            // Bottom panel: compact rounded glass, ≤640pt, centered.
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
            // No `.frame(maxWidth:)` — the panel sizes to its content
            // (scrubber row + transport row) so the right cluster sits
            // flush against the left cluster instead of being pushed to
            // a far edge by a Spacer that fills empty width. Centered by
            // the outer VStack's default alignment.
            .fixedSize(horizontal: true, vertical: false)
            .padding(.bottom, 24)
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

    private var subtitleLine: String {
        var parts: [String] = []
        if let studio = scene.studio?.name { parts.append(studio) }
        if let date = scene.date { parts.append(date) }
        if let f = scene.files.first, let w = f.width, let h = f.height {
            parts.append("\(w)×\(h)")
        }
        if let r = scene.rating100, r > 0 {
            parts.append(String(format: "★ %.1f", Double(r) / 20.0))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Top panel

/// Always-visible header strip that sits inline with the window's traffic
/// lights. Fully transparent background so the video shows through behind
/// the window controls; title + back-button rely on text shadows for
/// readability over bright video frames.
private struct OSDTopHeader: View {
    let title: String
    let subtitle: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            OSDIconButton(
                systemName: "chevron.backward",
                help: "Back to library",
                action: onClose
            )

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
                .lineLimit(1)

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
                    .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 0)
        }
        // Left padding clears the window's traffic lights so the back
        // button sits flush against them.
        .padding(.leading, 78)
        .padding(.trailing, 16)
        // Vertical padding sized to match the standard 28pt title-bar
        // height — the back button + title row visually aligns with the
        // traffic lights instead of floating below them.
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    var body: some View {
        VStack(spacing: 8) {
            scrubberRow
            transportRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(OSDPanelBackground(cornerRadius: 16))
        .foregroundStyle(.white)
    }

    private var displayedSeconds: Double {
        vm.seekDraftSeconds ?? vm.currentSeconds
    }

    private var scrubberRow: some View {
        HStack(spacing: 10) {
            Text(playhead(displayedSeconds))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 48, alignment: .trailing)

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
            // Pin the slider's width so the panel sizes to a predictable
            // compact width regardless of duration's label digits.
            .frame(width: 320)

            Text(playhead(vm.durationSeconds))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 48, alignment: .leading)
        }
    }

    private var transportRow: some View {
        HStack(spacing: 4) {
            // Left cluster — primary transport
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

            volumeCluster
                .padding(.leading, 8)

            // 14pt visual gap separates transport from the Stash-extras
            // cluster without the elastic Spacer that was stretching the
            // panel out to maxWidth.
            Color.clear.frame(width: 14, height: 0)

            // Right cluster — Stash extras + system extras
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
    }

    private var playPauseButton: some View {
        Button {
            vm.bumpReveal()
            vm.togglePlayPause()
        } label: {
            Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(vm.isPlaying ? "Pause (Space)" : "Play (Space)")
    }

    /// Volume is mute-button only by default; the slider only renders on
    /// hover to keep the transport row compact, matching Infuse's
    /// expandable speaker control.
    @State private var volumeHovered = false

    private var volumeCluster: some View {
        HStack(spacing: 2) {
            OSDIconButton(
                systemName: volumeIcon,
                help: vm.isMuted ? "Unmute (m)" : "Mute (m)"
            ) {
                vm.bumpReveal()
                vm.toggleMute()
            }

            if volumeHovered {
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
                .controlSize(.small)
                .frame(width: 70)
                .tint(.white)
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .onHover { volumeHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: volumeHovered)
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

/// Square icon button used throughout the OSD. White SF Symbol at 16pt,
/// 32pt hit target, gentle hover background. The frame is intentionally
/// just larger than the glyph so the buttons pack tightly together when
/// the row has many of them.
private struct OSDIconButton: View {
    let systemName: String
    let help: String
    var size: CGFloat = 16
    var tinted: Bool = false
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tinted ? .white : .white.opacity(hovered ? 1 : 0.88))
                .frame(width: 32, height: 32)
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
