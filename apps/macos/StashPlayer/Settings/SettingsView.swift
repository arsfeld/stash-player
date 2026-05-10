import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var url: String = ""
    @State private var apiKey: String = ""
    @State private var status: TestStatus = .idle

    enum TestStatus {
        case idle
        case testing
        case success(version: String)
        case failure(message: String)
    }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Stash URL", text: $url, prompt: Text("https://stash.example.com"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                SecureField("API key", text: $apiKey, prompt: Text("•••••••••"))
                    .textFieldStyle(.roundedBorder)
            }

            Section {
                HStack {
                    Button("Test connection") {
                        Task { await test() }
                    }
                    .disabled(url.isEmpty || apiKey.isEmpty || isTesting)

                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    statusLabel
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task { await preload() }
    }

    private var isTesting: Bool {
        if case .testing = status { return true }
        return false
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .idle:
            EmptyView()
        case .testing:
            Text("Connecting…").foregroundStyle(.secondary)
        case .success(let v):
            Label("Connected to Stash \(v)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let m):
            Label(m, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func preload() async {
        do {
            if let creds = try await app.loadSavedCredentials() {
                url = creds.baseUrl
                apiKey = creds.apiKey
            }
        } catch {
            // Best-effort prefill; ignore.
        }
    }

    private func test() async {
        status = .testing
        do {
            let version = try await app.connect(baseUrl: url, apiKey: apiKey)
            status = .success(version: version)
            // Auto-jump to library once we know we're connected.
            app.sidebarSelection = .library
        } catch let e as FfiError {
            status = .failure(message: errorMessage(e))
        } catch {
            status = .failure(message: error.localizedDescription)
        }
    }

    private func errorMessage(_ e: FfiError) -> String {
        switch e {
        case .Network(let m), .GraphQl(let m), .InvalidUrl(let m),
             .Config(let m), .Keychain(let m), .Io(let m):
            return m
        case .NotConnected:
            return "Not connected"
        }
    }
}
