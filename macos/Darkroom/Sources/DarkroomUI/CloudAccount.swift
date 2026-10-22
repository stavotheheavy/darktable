import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security

// Sign in to Databit Dev from Vantage (slice 1 of the cloud seam, 2026-10-22). Method: OAuth 2.0 authorization code with PKCE for
// native apps, RFC 7636 (S256) and RFC 8252 (the system browser session, a private-use URL scheme for the redirect). The browser
// session shares Safari's cookies, so an existing Databit login and its two-step check are reused; Vantage never sees a password.

public struct CloudUser: Codable, Equatable, Sendable {
    public var email: String
    public var name: String?
}

/// What the server says about the signed-in account.
public struct CloudLogin: Equatable, Sendable {
    public var token: String
    public var user: CloudUser
    /// Vantage Pro (cloud galleries and approvals). The server answers false until the billing slice lands.
    public var pro: Bool
}

public enum CloudError: LocalizedError, Equatable {
    case cancelled, denied, stateMismatch, badCallback, server(String), offline

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Sign in was cancelled"
        case .denied: "Databit Dev did not allow Vantage"
        case .stateMismatch, .badCallback: "The sign-in answer did not match the request, so Vantage ignored it"
        case .server(let m): m
        case .offline: "Could not reach Databit Dev"
        }
    }
}

public enum PKCE {
    /// 32 random bytes as 43 base64url characters.
    public static func verifier() -> String { base64url(Data((0..<32).map { _ in UInt8.random(in: 0...255) })) }
    public static func challenge(for verifier: String) -> String { base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    public static func state() -> String { base64url(Data((0..<16).map { _ in UInt8.random(in: 0...255) })) }
    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Where the device token lives between launches. The Keychain in the app; a dictionary in tests.
public protocol CloudTokenStore: AnyObject, Sendable {
    func read() -> String?
    func write(_ token: String)
    func delete()
}

public final class KeychainTokenStore: CloudTokenStore, @unchecked Sendable {
    private let service: String
    public init(service: String = "com.databitdev.vantage") { self.service = service }
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "device-token"] }

    public func read() -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    public func write(_ token: String) {
        delete()
        var q = query; q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(q as CFDictionary, nil)
    }
    public func delete() { SecItemDelete(query as CFDictionary) }
}

public final class MemoryTokenStore: CloudTokenStore, @unchecked Sendable {
    private var token: String?
    public init(_ token: String? = nil) { self.token = token }
    public func read() -> String? { token }
    public func write(_ token: String) { self.token = token }
    public func delete() { token = nil }
}

/// The three calls the server offers (src/pages/api/vantage/*), JSON only.
public struct CloudClient: Sendable {
    public var base: URL
    public var session: URLSession
    public static let callbackScheme = "vantage"

    public init(base: URL, session: URLSession = .shared) { self.base = base; self.session = session }

    /// The page the browser session opens: the user approves there.
    public func authorizeURL(state: String, challenge: String, device: String) -> URL {
        var c = URLComponents(url: base.appending(path: "vantage/authorize"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "challenge", value: challenge), URLQueryItem(name: "device", value: device)]
        return c.url!
    }

    /// The code in `vantage://auth?code=…&state=…`, after checking the state is the one we sent.
    public func code(fromCallback url: URL, expectedState: String) throws -> String {
        guard url.scheme == Self.callbackScheme, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { throw CloudError.badCallback }
        func item(_ n: String) -> String? { items.first { $0.name == n }?.value }
        guard item("state") == expectedState else { throw CloudError.stateMismatch }
        if item("error") != nil { throw CloudError.denied }
        guard let code = item("code"), !code.isEmpty else { throw CloudError.badCallback }
        return code
    }

    public func exchange(code: String, verifier: String) async throws -> CloudLogin {
        let (data, status) = try await send("api/vantage/token", method: "POST", body: ["code": code, "verifier": verifier])
        guard status == 200 else { throw CloudError.server(Self.message(data) ?? "Databit Dev refused the sign-in (\(status))") }
        guard let login = Self.login(data, tokenFallback: nil) else { throw CloudError.server("Databit Dev answered something Vantage cannot read") }
        return login
    }

    /// The account behind `token`, or nil when the server no longer knows it (signed out elsewhere).
    public func me(token: String) async throws -> CloudLogin? {
        let (data, status) = try await send("api/vantage/me", method: "GET", token: token)
        if status == 401 { return nil }
        guard status == 200, let login = Self.login(data, tokenFallback: token) else { throw CloudError.server(Self.message(data) ?? "Databit Dev answered \(status)") }
        return login
    }

    public func signOut(token: String) async {
        _ = try? await send("api/vantage/signout", method: "POST", token: token, body: [:])
    }

    private func send(_ path: String, method: String, token: String? = nil, body: [String: String]? = nil) async throws -> (Data, Int) {
        var r = URLRequest(url: base.appending(path: path))
        r.httpMethod = method
        r.timeoutInterval = 20
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, response) = try await session.data(for: r)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch { throw CloudError.offline }
    }

    private static func message(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
    }

    private static func login(_ data: Data, tokenFallback: String?) -> CloudLogin? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = (o["token"] as? String) ?? tokenFallback,
              let u = o["user"] as? [String: Any], let email = u["email"] as? String else { return nil }
        return CloudLogin(token: token, user: CloudUser(email: email, name: u["name"] as? String), pro: o["pro"] as? Bool ?? false)
    }
}

/// The system's web sign-in sheet. Cookies are shared with Safari, so a Databit login already there is reused.
@MainActor
final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func run(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: CloudClient.callbackScheme) { callback, error in
                if let callback { cont.resume(returning: callback) } else { cont.resume(throwing: CloudError.cancelled) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            session = s
            if !s.start() { cont.resume(throwing: CloudError.cancelled) }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { NSApp.keyWindow ?? ASPresentationAnchor() }
}

extension DarkroomModel {
    /// Databit Dev's address: `DARKROOM_CLOUD_URL`, else the `darkroom.cloudURL` default, else databitdev.com.
    public static var defaultCloudBase: URL {
        let raw = ProcessInfo.processInfo.environment["DARKROOM_CLOUD_URL"] ?? UserDefaults.standard.string(forKey: "darkroom.cloudURL") ?? "https://databitdev.com"
        return URL(string: raw) ?? URL(string: "https://databitdev.com")!
    }

    public var cloudSignedIn: Bool { cloudUser != nil }

    /// Signs in through the browser sheet. `browser` opens the authorize page and returns the redirect it ended on; tests pass a fake.
    public func signInToCloud(browser: ((URL) async throws -> URL)? = nil) async {
        guard !cloudBusy else { return }
        cloudBusy = true
        defer { cloudBusy = false }
        let verifier = PKCE.verifier(), state = PKCE.state()
        let device = Host.current().localizedName ?? "this Mac"
        let url = cloudClient.authorizeURL(state: state, challenge: PKCE.challenge(for: verifier), device: device)
        do {
            let callback: URL
            if let browser { callback = try await browser(url) } else { callback = try await WebSignIn().run(url) }
            let code = try cloudClient.code(fromCallback: callback, expectedState: state)
            let login = try await cloudClient.exchange(code: code, verifier: verifier)
            cloudStore.write(login.token)
            cloudUser = login.user
            cloudPro = login.pro
            cloudMessage = "Signed in as \(login.user.email)"
        } catch CloudError.cancelled {
            cloudMessage = nil
        } catch {
            cloudMessage = (error as? CloudError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Signs out here and tells the server to forget this Mac.
    public func signOutOfCloud() async {
        if let token = cloudStore.read() { await cloudClient.signOut(token: token) }
        cloudStore.delete()
        cloudUser = nil
        cloudPro = false
        cloudMessage = "Signed out of Databit Dev"
    }

    /// On launch: ask the server who the saved token belongs to. A token the server no longer knows is dropped; no network keeps the
    /// saved sign-in as it was.
    public func refreshCloud() async {
        guard let token = cloudStore.read() else { cloudUser = nil; return }
        do {
            if let login = try await cloudClient.me(token: token) { cloudUser = login.user; cloudPro = login.pro }
            else { cloudStore.delete(); cloudUser = nil; cloudPro = false; cloudMessage = "You were signed out of Databit Dev" }
        } catch { /* offline: keep what we have */ }
    }
}

extension DarkroomModel {
    /// Asks Databit Dev for the picks of every gallery sent from this Mac and keeps them by photo. Quiet unless `force` when it ran in
    /// the last five minutes; a failure keeps the picks already known and says why.
    public func refreshClientPicks(force: Bool = false) async {
        guard !clientPicksBusy, let token = cloudStore.read() else { return }
        if !force, let at = clientPicksFetchedAt, Date().timeIntervalSince(at) < 300 { return }
        let galleries = clientPickStore.galleries()
        guard !galleries.isEmpty else { return }
        clientPicksBusy = true
        defer { clientPicksBusy = false }
        let client = GalleryClient(base: cloudClient.base, session: cloudClient.session)
        var found: [String: ClientPick] = [:]
        var problem: String?
        for g in galleries {
            do {
                let r = try await client.picks(token: token, site: g.siteID, gallery: g.id)
                for (name, choice) in r.choices {
                    guard let path = g.files[name] else { continue }
                    let pick = ClientPick(choice: choice, gallery: g.title, sentAt: r.picksSentAt, note: r.note)
                    // a photo in two galleries keeps the newest answer
                    if let old = found[path], (old.sentAt ?? .distantPast) >= (pick.sentAt ?? .distantPast) { continue }
                    found[path] = pick
                }
            } catch { problem = (error as? GalleryError)?.errorDescription ?? error.localizedDescription }
        }
        if let problem { clientPicksMessage = problem; return }
        clientPicksFetchedAt = Date()
        clientPicks = found
        clientPickStore.savePicks(found)
        clientPicksMessage = found.isEmpty ? "No client picks yet" : "\(found.count) client picks"
    }
}

extension DarkroomModel {
    /// The Databit Dev page where Vantage Pro is bought and managed. Vantage opens it in the browser; the app never takes a card.
    public var subscribeURL: URL { cloudClient.base.appending(path: "portal/vantage") }

    public func openSubscribe() { NSWorkspace.shared.open(subscribeURL) }
}
