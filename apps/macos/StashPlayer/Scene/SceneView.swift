import SwiftUI
import AVKit
import AVFoundation

struct SceneView: View {
    let scene: FfiScene
    @EnvironmentObject var app: AppState
    @State private var avPlayer: AVPlayer?
    @State private var loadError: String?
    @State private var lastPlayStart: Date?
    @State private var accumulatedPlayDuration: Double = 0
    @State private var rateObserver: NSKeyValueObservation?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                videoSurface
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                metadata

                if let details = scene.details, !details.isEmpty {
                    Text(details)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                fileInfo
            }
            .padding(20)
        }
        .navigationTitle(scene.displayTitle)
        .task { await loadPlayer() }
        .onDisappear(perform: handleDisappear)
    }

    @ViewBuilder
    private var videoSurface: some View {
        if let avPlayer {
            VideoPlayer(player: avPlayer)
        } else if let loadError {
            VStack {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                Text(loadError).foregroundStyle(.secondary).padding()
            }
        } else {
            ProgressView()
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
        return parts.joined(separator: " · ")
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(scene.displayTitle).font(.title)
            if !subtitleLine.isEmpty {
                Text(subtitleLine).foregroundStyle(.secondary)
            }
            if !scene.performers.isEmpty {
                Text(scene.performers.map(\.name).joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var fileInfo: some View {
        if let f = scene.files.first {
            GroupBox("File") {
                VStack(alignment: .leading, spacing: 4) {
                    if let codec = f.videoCodec {
                        labelRow("Codec", codec)
                    }
                    if let w = f.width, let h = f.height {
                        labelRow("Resolution", "\(w)×\(h)")
                    }
                    if let fps = f.frameRate {
                        labelRow("Frame rate", String(format: "%.2f fps", fps))
                    }
                    if let dur = f.duration {
                        labelRow("Duration", formatDuration(dur))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func labelRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    @MainActor
    private func loadPlayer() async {
        guard let stream = scene.paths.stream else {
            loadError = "Scene has no stream URL"
            return
        }
        do {
            let signed = try app.authenticatedUrl(stream)
            guard let url = URL(string: signed) else {
                loadError = "Bad stream URL"
                return
            }
            let player = AVPlayer(url: url)
            attachRateObserver(player)
            avPlayer = player

            if let resume = scene.resumeTime, resume > 5 {
                let target = CMTime(seconds: resume, preferredTimescale: 600)
                await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
            }
            player.play()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func attachRateObserver(_ player: AVPlayer) {
        rateObserver = player.observe(\.rate, options: [.old, .new]) { _, change in
            let oldRate = change.oldValue ?? 0
            let newRate = change.newValue ?? 0
            Task { @MainActor in
                if newRate > 0 && oldRate == 0 {
                    lastPlayStart = Date()
                } else if newRate == 0 && oldRate > 0 {
                    if let start = lastPlayStart {
                        accumulatedPlayDuration += Date().timeIntervalSince(start)
                        lastPlayStart = nil
                    }
                }
            }
        }
    }

    private func handleDisappear() {
        rateObserver?.invalidate()
        rateObserver = nil
        guard let player = avPlayer else { return }

        let resume = player.currentTime().seconds
        var play = accumulatedPlayDuration
        if let start = lastPlayStart {
            play += Date().timeIntervalSince(start)
        }
        let id = scene.id
        let duration: Double? = play > 0 ? play : nil
        let resumeOpt: Double? = resume.isFinite ? resume : nil

        player.pause()
        avPlayer = nil

        Task { [app] in
            await app.saveActivity(id: id, resumeTime: resumeOpt, playDuration: duration)
        }
    }
}
