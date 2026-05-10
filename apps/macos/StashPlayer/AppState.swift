import Foundation
import AppKit

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected(version: String)
    case failed(message: String)
}

enum SidebarItem: Hashable {
    case library
    case settings
}

@MainActor
final class AppState: ObservableObject {
    let player: StashPlayer
    @Published var status: ConnectionStatus = .disconnected
    @Published var sidebarSelection: SidebarItem = .settings

    init() {
        initLogging()
        self.player = StashPlayer()
    }

    /// Called once at launch. Loads saved credentials from disk + Keychain
    /// and tries to connect. On success the user lands in Library; on
    /// anything else they stay in Settings.
    func bootstrap() async {
        let player = self.player
        do {
            let creds = try await offMain { try player.loadSavedCredentials() }
            guard let creds else {
                sidebarSelection = .settings
                return
            }
            status = .connecting
            let version = try await offMain {
                try player.connect(baseUrl: creds.baseUrl, apiKey: creds.apiKey)
            }
            status = .connected(version: version)
            sidebarSelection = .library
        } catch {
            status = .failed(message: humanize(error))
            sidebarSelection = .settings
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

    func listScenes(query: String?, page: UInt32, perPage: UInt32 = 24) async throws -> FfiScenesPage {
        let player = self.player
        return try await offMain {
            try player.listScenes(query: query, page: page, perPage: perPage)
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

    func authenticatedUrl(_ raw: String) throws -> String {
        try player.authenticatedUrl(url: raw)
    }

    func fetchThumbnail(url: String) async throws -> NSImage? {
        let player = self.player
        let data = try await offMain { try player.fetchThumbnail(url: url) }
        return NSImage(data: data)
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
