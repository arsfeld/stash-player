import Sparkle
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var updaterViewModel: CheckForUpdatesViewModel
    @State private var url: String = ""
    @State private var apiKey: String = ""
    @State private var proxyUrl: String = ""
    @State private var status: TestStatus = .idle
    @State private var autoCheck: Bool

    private let updater: SPUUpdater

    enum TestStatus {
        case idle
        case testing
        case success(version: String)
        case failure(message: String)
    }

    init(updater: SPUUpdater) {
        self.updater = updater
        // Property wrappers require their backing storage to be initialized
        // through their wrapper type when set from a custom init.
        self._updaterViewModel = StateObject(
            wrappedValue: CheckForUpdatesViewModel(updater: updater)
        )
        self._autoCheck = State(initialValue: updater.automaticallyChecksForUpdates)
    }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Stash URL", text: $url, prompt: Text("https://stash.example.com"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                SecureField("API key (optional)", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                TextField(
                    "Proxy (optional)",
                    text: $proxyUrl,
                    prompt: Text("socks5://127.0.0.1:1055")
                )
                .textFieldStyle(.roundedBorder)
                .help("Used for both API calls and video playback. Accepts http://, https://, socks5:// and socks5h://.")
            }

            Section {
                HStack {
                    Button("Test connection") {
                        Task { await test() }
                    }
                    .disabled(url.isEmpty || isTesting)

                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    statusLabel
                }
            }

            Section("Updates") {
                LabeledContent("Version", value: Bundle.main.versionDisplay)
                Toggle("Automatically check for updates", isOn: $autoCheck)
                    .onChange(of: autoCheck) { _, newValue in
                        // Sparkle's docs: write only in response to direct user
                        // interaction. Do not re-read on view appearance.
                        updater.automaticallyChecksForUpdates = newValue
                    }
                HStack {
                    Button("Check for Updates Now") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updaterViewModel.canCheckForUpdates)
                    Spacer()
                    Text("Last checked: \(lastCheckedLabel)")
                        .foregroundStyle(.secondary)
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

    private var lastCheckedLabel: String {
        if let date = updaterViewModel.lastUpdateCheckDate {
            return date.formatted(.relative(presentation: .named))
        } else {
            return "Never"
        }
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
                proxyUrl = creds.proxyUrl
            }
        } catch {
            // Best-effort prefill; ignore.
        }
    }

    private func test() async {
        status = .testing
        do {
            let version = try await app.connect(baseUrl: url, apiKey: apiKey, proxyUrl: proxyUrl)
            status = .success(version: version)
            // The main window picks up the new connection state via
            // `AppState.status` and swaps the placeholder for the library.
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

private extension Bundle {
    var versionDisplay: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
