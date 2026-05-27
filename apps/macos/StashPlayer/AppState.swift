import Foundation
import AppKit

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected(version: String)
    case failed(message: String)
}

/// Filter state owned by the library view. We keep a Swift-side struct so
/// SwiftUI can diff it cheaply and so we can hash it for `task(id:)`-style
/// reload triggers. It maps one-to-one to `FfiSceneFilter`.
struct LibraryFilter: Hashable {
    var query: String = ""
    var sort: FfiSortKey = .createdAt
    var direction: FfiSortDirection = .desc
    /// Stash's rating100 scale (20/40/60/80/100). nil means "any rating".
    var minRating: Int32? = nil
    /// nil = don't filter, true/false = restrict to organized/unorganized.
    var organized: Bool? = nil
    /// Default ON — opens to the "untracked" view, matching the Linux app.
    var hideTracked: Bool = true
    /// Mirrors the toolbar "Hide interactive" toggle; persisted in
    /// LibraryView via @AppStorage so the choice survives app restarts.
    var hideInteractive: Bool = false
    /// Set when sort == .random so paging + neighbor lookups stay stable.
    var randomSeed: UInt32? = nil

    func toFfi() -> FfiSceneFilter {
        FfiSceneFilter(
            query: query.isEmpty ? nil : query,
            sort: sort,
            direction: direction,
            minRating: minRating,
            organized: organized,
            hideTracked: hideTracked,
            // `false` excludes interactive scenes; nil means "no filter".
            // Matches the Linux UI's translation.
            interactive: hideInteractive ? false : nil,
            randomSeed: randomSeed
        )
    }
}

@MainActor
final class AppState: ObservableObject {
    let player: StashPlayer
    @Published var status: ConnectionStatus = .disconnected

    /// Incremented by menu commands to trigger actions in the active
    /// library view. The view observes these with `.onChange(of:)`.
    @Published var refreshTrigger = 0
    @Published var scanTrigger = 0

    init() {
        initLogging()
        self.player = StashPlayer()
    }

    /// Called once at launch. Loads saved credentials from disk + Keychain
    /// and tries to connect. On failure the main window shows an
    /// "Open Settings" placeholder; the user opens the Settings scene
    /// (Cmd-,) to enter credentials.
    func bootstrap() async {
        let player = self.player
        do {
            let creds = try await offMain { try player.loadSavedCredentials() }
            guard let creds else { return }
            status = .connecting
            let version = try await offMain {
                try player.connect(baseUrl: creds.baseUrl, apiKey: creds.apiKey)
            }
            status = .connected(version: version)
        } catch {
            status = .failed(message: humanize(error))
        }
    }

    /// Save creds + verify them + cache the live client.
    func connect(baseUrl: String, apiKey: String) async throws -> String {
        let player = self.player
        status = .connecting
        do {
            let version = try await offMain {
                try player.saveCredentials(baseUrl: baseUrl, apiKey: apiKey)
                return try player.connect(baseUrl: baseUrl, apiKey: apiKey)
            }
            status = .connected(version: version)
            return version
        } catch {
            status = .failed(message: humanize(error))
            throw error
        }
    }

    func loadSavedCredentials() async throws -> FfiCredentials? {
        let player = self.player
        return try await offMain { try player.loadSavedCredentials() }
    }

    func listScenes(
        filter: LibraryFilter,
        page: UInt32,
        perPage: UInt32 = 24
    ) async throws -> FfiScenesPage {
        let player = self.player
        let ffi = filter.toFfi()
        return try await offMain {
            try player.listScenes(filter: ffi, page: page, perPage: perPage)
        }
    }

    func getScene(id: String) async throws -> FfiScene? {
        let player = self.player
        return try await offMain { try player.getScene(id: id) }
    }

    func saveActivity(id: String, resumeTime: Double?, playDuration: Double?) async {
        let player = self.player
        do {
            _ = try await offMain {
                try player.saveActivity(id: id, resumeTime: resumeTime, playDuration: playDuration)
            }
        } catch {
            // Best-effort; surface in logs only.
            NSLog("saveActivity failed: %@", String(describing: error))
        }
    }

    func incrementO(id: String) async throws -> Int32 {
        let player = self.player
        return try await offMain { try player.incrementO(id: id) }
    }

    func resetO(id: String) async throws -> Int32 {
        let player = self.player
        return try await offMain { try player.resetO(id: id) }
    }

    func authenticatedUrl(_ raw: String) throws -> String {
        try player.authenticatedUrl(url: raw)
    }

    func fetchThumbnail(url: String) async throws -> NSImage? {
        let player = self.player
        let data = try await offMain { try player.fetchThumbnail(url: url) }
        return NSImage(data: data)
    }

    /// Trigger a metadata scan on the server. Returns the job ID so the
    /// caller can poll progress via `jobs()`.
    func metadataScan() async throws -> String {
        let player = self.player
        return try await offMain { try player.metadataScan() }
    }

    /// List all currently tracked jobs (running + recently completed).
    func jobs() async throws -> [FfiJob] {
        let player = self.player
        return try await offMain { try player.jobs() }
    }
}

private func offMain<T: Sendable>(
    _ work: @Sendable @escaping () throws -> T
) async throws -> T {
    try await Task.detached(priority: .userInitiated) {
        try work()
    }.value
}

private func humanize(_ error: Error) -> String {
    if let ffi = error as? FfiError {
        switch ffi {
        case .Network(let m): return "Network error: \(m)"
        case .GraphQl(let m): return "Server error: \(m)"
        case .NotConnected: return "Not connected"
        case .InvalidUrl(let m): return "Invalid URL: \(m)"
        case .Config(let m): return "Config error: \(m)"
        case .Keychain(let m): return "Keychain error: \(m)"
        case .Io(let m): return "I/O error: \(m)"
        }
    }
    return error.localizedDescription
}
