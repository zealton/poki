import AuthenticationServices
import Darwin
import Foundation
import PiSwiftAI
import SwiftUI
import WebKit

/// The ChatGPT sign-in: OpenAI's Sign in with ChatGPT for open-source apps
/// (developers.openai.com/siwc/token-sharing-open-source), through PiSwiftAI's `loginOpenAIChatGPT`.
/// The first sign-in registers Poki with `dynamic_agent_client` and this installation's id; the page
/// opens in ASWebAuthenticationSession and redirects to a listener inside Poki on
/// http://127.0.0.1:1455/auth/callback, the only redirect the flow accepts. The chat then runs on the
/// OpenAI API (Responses, store off) on the owner's ChatGPT plan. Poki does not use Codex's own client.
///
/// The tokens go into the keychain as one JSON item and are never printed or logged.
enum ChatGPTAccount {
    static func decode(_ stored: String) -> OAuthCredentials? {
        try? JSONDecoder().decode(OAuthCredentials.self, from: Data(stored.utf8))
    }

    static func save(_ credentials: OAuthCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        try ModelKeys.save(String(decoding: data, as: UTF8.self), for: .chatgpt)
    }

    static var signedIn: Bool { ModelKeys.key(.chatgpt).flatMap(decode)?.clientId?.isEmpty == false }

    /// This installation's id for OpenAI's registration (`ext_agent_host_id`), made once.
    static var installationID: String {
        if let id = UserDefaults.standard.string(forKey: "chat.installationID") { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "chat.installationID")
        return id
    }
}

@MainActor
final class ChatGPTBrowserLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// In-app: OpenAI's page opens in Poki's own sheet, which hands the last redirect (to Poki's listener
    /// on 127.0.0.1) straight to the listener, so no browser ever loads that local address (Safari tried
    /// it over https first and showed a certificate warning). Off: the system sign-in sheet.
    var inApp = true
    /// The page to show in the in-app sheet; set while signing in.
    var pageURL: URL?
    var onPage: ((URL?) -> Void)?
    private var session: ASWebAuthenticationSession?
    private var manual: CheckedContinuation<String, Error>?
    private let cancel = CancellationToken()

    struct Cancelled: LocalizedError { var errorDescription: String? { String(localized: "Sign-in was cancelled.") } }

    func signIn() async throws -> OAuthCredentials {
        let callbacks = OAuthLoginCallbacks(
            onAuth: { [weak self] info in self?.open(info.url) },
            // The listener answers first; this only ends when the owner closes the sign-in sheet.
            onPrompt: { [weak self] _ in
                try await withCheckedThrowingContinuation { continuation in self?.manual = continuation }
            },
            signal: cancel,
            getDeviceId: { [id = ChatGPTAccount.installationID] in id },
            agentName: "Poki"
        )
        defer { finish() }
        return try await loginOpenAIChatGPT(callbacks)
    }

    private func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        if inApp { pageURL = url; onPage?(url); return }
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme("poki")) { [weak self] _, _ in
            // Closed by the owner (the redirect goes to the listener, not to this callback).
            Task { @MainActor in self?.closed() }
        }
        session.presentationContextProvider = self
        self.session = session
        session.start()
    }

    private func closed() {
        session = nil
        manual?.resume(throwing: Cancelled())
        manual = nil
        cancel.cancel()
    }

    /// The in-app sheet was closed before the sign-in finished.
    func pageClosed() {
        guard pageURL != nil else { return }
        pageURL = nil
        closed()
    }

    private func finish() {
        pageURL = nil
        onPage?(nil)
        session?.cancel()
        session = nil
        manual?.resume(throwing: Cancelled())
        manual = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}

/// The ChatGPT row's sheet: sign in, or sign out.
struct ChatGPTSignIn: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var working = false
    @State private var problem: String?
    @State private var login = ChatGPTBrowserLogin()
    @State private var page: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Continue with ChatGPT") { login.inApp = true; run { try await login.signIn() } }.disabled(working)
                    Button("Continue in Safari") { login.inApp = false; run { try await login.signIn() } }.disabled(working)
                } footer: {
                    Text("Poki uses your ChatGPT Plus or Pro plan through OpenAI’s Sign in with ChatGPT. The sign-in stays in this iPhone’s Keychain. An OpenAI API key works too, as a backup: add it under OpenAI.")
                }
                if let problem { Text(verbatim: problem).foregroundStyle(Color(.systemRed)) }
                if ChatGPTAccount.signedIn {
                    Section { Button("Sign Out", role: .destructive) { ModelKeys.remove(.chatgpt); dismiss() } }
                }
            }
            .navigationTitle(Text(verbatim: "ChatGPT"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { login.onPage = { page = $0 } }
            .sheet(item: $page, onDismiss: { login.pageClosed() }) { url in
                NavigationStack {
                    SignInPage(url: url)
                        .ignoresSafeArea(edges: .bottom)
                        .navigationTitle(Text(verbatim: "ChatGPT"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { page = nil } } }
                }
            }
        }
    }

    private func run(_ signIn: @escaping () async throws -> OAuthCredentials) {
        problem = nil
        working = true
        Task {
            do { done(try await signIn()) } catch { problem = error.localizedDescription }
            working = false
        }
    }

    private func done(_ credentials: OAuthCredentials) {
        do {
            try ChatGPTAccount.save(credentials)
            ModelKeys.selectedProvider = .chatgpt
            dismiss()
        } catch {
            problem = String(localized: "The keychain did not take the sign-in. Try again.")
        }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

/// OpenAI's sign-in page in Poki. The redirect to Poki's own listener (127.0.0.1 or localhost, port
/// 1455, http or https) is not loaded: it is sent to the listener over plain http from here, which ends
/// the sign-in and closes this sheet.
struct SignInPage: UIViewRepresentable {
    var url: URL

    func makeCoordinator() -> SignInRedirect { SignInRedirect() }

    func makeUIView(context: UIViewRepresentableContext<SignInPage>) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator
        view.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: UIViewRepresentableContext<SignInPage>) {}
}

/// Hands the redirect to Poki's own listener instead of loading it.
final class SignInRedirect: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let target = navigationAction.request.url, ["127.0.0.1", "localhost"].contains(target.host() ?? ""), target.port == 1455,
              var parts = URLComponents(url: target, resolvingAgainstBaseURL: false) else { decisionHandler(.allow); return }
        parts.scheme = "http"
        parts.host = "127.0.0.1"
        if let local = parts.url { URLSession.shared.dataTask(with: local).resume() }
        decisionHandler(.cancel)
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Simulator test runs only: `SIMCTL_CHILD_POKI_TEST_CREDENTIAL=<file>` names a JSON file on the Mac,
/// `{"provider": "chatgpt"|"anthropic"|…, "model"?: id, "secret": key or credential JSON}`. It is read
/// once at launch into the keychain and the provider is selected. Nothing is printed.
enum TestCredential {
    static func importIfGiven() {
        if let path = ProcessInfo.processInfo.environment["POKI_TEST_CREDENTIAL_FIFO"] {
            importFIFO(path)
            return
        }
        guard let path = ProcessInfo.processInfo.environment["POKI_TEST_CREDENTIAL"],
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let provider = (json["provider"] as? String).flatMap(ModelProvider.init(rawValue:)),
              let secret = json["secret"] as? String else { return }
        guard (try? ModelKeys.save(secret, for: provider)) != nil else { return }
        ModelKeys.selectedProvider = provider
        if let model = json["model"] as? String {
            ModelCatalog.set(model, on: true, for: provider)
            ModelKeys.selectedModel = model
        }
    }

    /// Explicit Debug Simulator provisioning without a plaintext credential file or a secret in
    /// argv/environment. The environment names only a private, owner-owned FIFO; read at most 16 KiB.
    private static func importFIFO(_ path: String) {
        var before = stat()
        guard lstat(path, &before) == 0, (before.st_mode & S_IFMT) == S_IFIFO,
              before.st_uid == getuid(), (before.st_mode & 0o077) == 0 else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let fd = open(path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var after = stat()
            guard fstat(fd, &after) == 0, after.st_ino == before.st_ino,
                  after.st_dev == before.st_dev else { return }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while data.count <= 16_384 {
                let count = read(fd, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 { return }
                data.append(contentsOf: buffer.prefix(count))
            }
            guard data.count <= 16_384,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let provider = (json["provider"] as? String).flatMap(ModelProvider.init(rawValue:)),
                  let secret = json["secret"] as? String else { return }
            DispatchQueue.main.async {
                do {
                    try ModelKeys.save(secret, for: provider)
                    ModelKeys.selectedProvider = provider
                    if let model = json["model"] as? String {
                        ModelCatalog.set(model, on: true, for: provider)
                        ModelKeys.selectedModel = model
                    }
                    AppLog.shared.add("model", "Simulator credential imported for \(provider.name)\(ModelKeys.isMemoryOnly(provider) ? " (memory only)" : "")")
                } catch {
                    AppLog.shared.add("model", "Simulator credential import failed; enter it in Accounts")
                }
            }
        }
    }
}
#endif
