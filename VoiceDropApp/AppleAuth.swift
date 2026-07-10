import Foundation
import Observation
import Security
import CryptoKit
import AuthenticationServices
import UIKit

/// Holds the per-user session token minted by jianshuo.dev/files after a
/// "Sign in with Apple" exchange. The token is the bearer credential for this
/// user's own `users/<sub>/` space — it is NOT a device id and NOT the old
/// shared master token.
///
/// Stored in the Keychain with iCloud Keychain sync on, so reinstalling or
/// switching to a new device recovers the same account (and therefore the same
/// recordings) without re-uploading anything.
@MainActor
@Observable
final class AuthStore {
    static let shared = AuthStore()

    private(set) var session: String?
    private(set) var anonToken: String = ""
    var lastError: String?
    var isAuthenticated: Bool { session != nil }

    /// The default credential for ALL API calls: the anonymous iCloud-Keychain token
    /// (zero-login; same Apple ID -> same token across devices and reinstalls; always
    /// non-empty). Apple sign-in does NOT change the default — the session's scope is
    /// itself `users/anon-<hash>/` (auth/apple binds the Apple ID to this anon box), so
    /// anon and session resolve to the SAME user_sub. The session JWT (`session`) is sent
    /// ONLY where the server demands an Apple-verified identity: community share/unshare.
    var bearer: String { anonToken }

    /// The user-facing identity string — exactly the server's storage prefix
    /// (`users/<anonId>/`). Safe to show and share: it's a one-way hash of the
    /// secret, not the secret itself. Lets the owner pin "which folder is me".
    var anonId: String {
        let hex = SHA256.hash(data: Data(anonToken.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "anon-" + String(hex.prefix(32))
    }

    /// Where the session is exchanged.
    private let authURL = API.filesBase.appendingPathComponent("auth/apple")

    private var appleCoordinator: AppleSignInCoordinator?

    private let service = "dev.jianshuo.voicedrop"
    private let sessionAccount = "session"
    private let anonAccount = "anon-id"

    private init() {
        session = keychainLoad(account: sessionAccount)
        if let s = session, isJWTExpired(s) { keychainDelete(account: sessionAccount); session = nil }
        anonToken = loadOrCreateAnon()
        #if DEBUG
        // Simulator screenshot rig: SIMCTL_CHILD_VD_ADOPT_TOKEN=anon_… simctl launch …
        // adopts a real account before anyone reads `bearer`. DEBUG-only.
        if let t = ProcessInfo.processInfo.environment["VD_ADOPT_TOKEN"],
           t.hasPrefix("anon_"), t.count >= 20 {
            keychainSave(t, account: anonAccount)
            anonToken = t
        }
        #endif
        AppGroup.publishBearer(anonToken)   // mirror to the Share Extension
    }

    /// True if a JWT's `exp` (Unix seconds) is in the past, or it can't be parsed.
    private func isJWTExpired(_ jwt: String) -> Bool {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return true }
        guard let data = Data(base64URLEncoded: String(parts[1])),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = obj["exp"] as? Double else { return true }
        return Date().timeIntervalSince1970 >= exp
    }

    /// A stable per-user secret with no login. Stored in the iCloud-synced
    /// Keychain, so the same Apple ID recovers the same token on every device.
    private func loadOrCreateAnon() -> String {
        if let existing = keychainLoad(account: anonAccount), !existing.isEmpty { return existing }
        let token = "anon_" + randomHex(32)
        keychainSave(token, account: anonAccount)
        return token
    }

    private func randomHex(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Exchange a Sign-in-with-Apple identity token for a long-lived session JWT.
    /// On success the session is persisted and `isAuthenticated` flips true.
    func exchange(identityToken: String, fullName: String? = nil, email: String? = nil) async {
        var req = URLRequest(url: authURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setBearer(anonToken)
        var payload: [String: Any] = ["identityToken": identityToken]
        if let fullName { payload["fullName"] = fullName }
        if let email { payload["email"] = email }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                lastError = "登录失败（服务器拒绝）"
                return
            }
            guard
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let token = obj["session"] as? String, !token.isEmpty
            else {
                lastError = "登录失败（无效响应）"
                return
            }
            keychainSave(token, account: sessionAccount)
            session = token
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() {
        keychainDelete(account: sessionAccount)
        session = nil
    }

    /// Present the system Sign-in-with-Apple sheet, then exchange the identity
    /// token for a session JWT bound to this user's existing anon box.
    func signInWithApple() async {
        defer { appleCoordinator = nil }
        let req = ASAuthorizationAppleIDProvider().createRequest()
        req.requestedScopes = [.fullName, .email]
        do {
            let auth = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ASAuthorization, Error>) in
                let c = AppleSignInCoordinator(cont)
                appleCoordinator = c
                let ctrl = ASAuthorizationController(authorizationRequests: [req])
                c.controller = ctrl
                ctrl.delegate = c
                ctrl.presentationContextProvider = c
                ctrl.performRequests()
            }
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = cred.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8) else {
                lastError = "登录失败（无身份令牌）"; return
            }
            // Apple hands over fullName/email ONLY on the first authorization — capture
            // them now and forward to the server, or they are gone for good.
            let displayName: String? = cred.fullName.flatMap {
                let s = PersonNameComponentsFormatter().string(from: $0)
                return s.isEmpty ? nil : s
            }
            await exchange(identityToken: idToken, fullName: displayName, email: cred.email)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Reset the anonymous identity: mint a brand-new token. The old
    /// `users/<id>/` space (recordings + articles) becomes unreachable — this is
    /// irreversible. Used by the account page's 重置身份.
    func resetAnonymous() {
        let token = "anon_" + randomHex(32)
        keychainSave(token, account: anonAccount)
        anonToken = token
        AppGroup.publishBearer(anonToken)   // keep the Share Extension in sync
    }

    /// Adopt an anon_… token received from another device (device-link login).
    /// Overwrites the local anon identity in the iCloud Keychain; `anonId`/`bearer`
    /// recompute automatically (computed properties on an @Observable).
    func adoptToken(_ token: String) {
        guard token.hasPrefix("anon_"), token.count >= 20 else { return }
        session = nil
        keychainDelete(account: sessionAccount)
        keychainSave(token, account: anonAccount)
        anonToken = token
        AppGroup.publishBearer(anonToken)   // keep the Share Extension in sync
    }

    // MARK: - Keychain (synchronizable = iCloud Keychain)

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
    }

    private func keychainSave(_ value: String, account: String) {
        let data = Data(value.utf8)
        var q = baseQuery(account)
        SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    private func keychainLoad(account: String) -> String? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = kCFBooleanTrue!
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8)
        else { return nil }
        return s
    }

    private func keychainDelete(account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}

// MARK: - Sign-in-with-Apple coordinator

private final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding, @unchecked Sendable {
    let cont: CheckedContinuation<ASAuthorization, Error>
    var controller: ASAuthorizationController?
    init(_ cont: CheckedContinuation<ASAuthorization, Error>) { self.cont = cont }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) { cont.resume(returning: authorization) }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) { cont.resume(throwing: error) }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}
