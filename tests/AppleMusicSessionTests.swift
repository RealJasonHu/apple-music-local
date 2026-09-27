import Foundation
import Darwin

// Synthetic data only. This executable never constructs a WKWebView or accesses
// the application's real cookie file or persistent WebKit data store.
@main
struct AppleMusicSessionTests {
    private static var checks = 0
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppleMusicSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("private/cookies.txt")
        let expiry = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 3600)
        let cookie = makeCookie(expiry: expiry)
        check(AppleMusicCookieFile.isValid(cookie), "synthetic cookie accepted")
        check(try AppleMusicCookieFile.write(cookie, to: file), "first atomic write reports change")
        check(!(try AppleMusicCookieFile.write(cookie, to: file)), "identical write reports no change")
        let restored = try AppleMusicCookieFile.read(from: file)!
        check(restored.expiresDate == expiry, "server expiry retained exactly")
        check(restored.isSecure, "secure attribute retained")
        check(restored.isHTTPOnly, "HttpOnly attribute retained")
        check(restored.domain == ".music.apple.com", "domain retained")
        var info = stat()
        check(lstat(file.path, &info) == 0 && info.st_mode & 0o777 == 0o600, "cookie permissions are 0600")
        check(lstat(file.deletingLastPathComponent().path, &info) == 0 && info.st_mode & 0o777 == 0o700, "private directory permissions are 0700")

        let session = makeCookie(expiry: nil)
        check(session.isSessionOnly, "synthetic session cookie has no expiry")
        _ = try AppleMusicCookieFile.write(session, to: file)
        let content = try String(contentsOf: file, encoding: .utf8)
        check(content.contains("\t0\tmedia-user-token\t"), "session expiry encoded as zero")
        check(try AppleMusicCookieFile.read(from: file)?.expiresDate == nil, "session expiry not extended")
        check(!AppleMusicCookieFile.isValid(makeCookie(expiry: Date(timeIntervalSinceNow: -1))), "expired cookie rejected")
        check(!AppleMusicCookieFile.isValid(makeCookie(domain: ".music.apple.com.evil.example")), "suffix lookalike rejected")
        check(!AppleMusicCookieFile.isValid(makeCookie(domain: ".apple.com")), "broader Apple cookie rejected")
        check(!AppleMusicCookieFile.isValid(makeCookie(value: "synthetic;bad")), "cookie delimiter injection rejected")

        let expiredFile = "# Netscape HTTP Cookie File\n.music.apple.com\tTRUE\t/\tTRUE\t1\tmedia-user-token\tsynthetic-expired\n"
        try expiredFile.write(to: file, atomically: true, encoding: .utf8)
        check(try AppleMusicCookieFile.read(from: file) == nil, "expired file not restored")
        try AppleMusicCookieFile.remove(at: file)
        try AppleMusicCookieFile.remove(at: file)
        check(!FileManager.default.fileExists(atPath: file.path), "removal is idempotent")

        let victim = directory.appendingPathComponent("unrelated.txt")
        try Data("untouched".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: victim)
        do { _ = try AppleMusicCookieFile.write(cookie, to: file); fatalError("symlink accepted") }
        catch AppleMusicCookieFile.StorageError.unsafePath { }
        check(try String(contentsOf: victim, encoding: .utf8) == "untouched", "symlink target left untouched")

        // Exercise the exact failure-result helper used by disconnect, then
        // reconstruct revocation state as a new launch would. No WK store or
        // app preferences are touched; the suite and all files are temporary.
        let suiteName = "AppleMusicSessionTests.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suiteName)!
        defer { isolatedDefaults.removePersistentDomain(forName: suiteName) }
        let revocation = AppleMusicCredentialRevocation(cookieURL: file, defaults: isolatedDefaults)
        check(!revocation.isRevoked, "fresh fixture has no revocation")
        check(revocation.record(), "revocation persisted before failed deletion")
        switch AppleMusicSession.removeCredentialAfterDisconnect(at: file, revocationRecorded: true) {
        case .failure(.credentialRemovalFailed): checks += 1
        default: fatalError("failed deletion reported success")
        }
        let relaunched = AppleMusicCredentialRevocation(cookieURL: file, defaults: UserDefaults(suiteName: suiteName)!)
        check(relaunched.isRevoked, "failed cleanup remains revoked on a new instance")
        check(try String(contentsOf: victim, encoding: .utf8) == "untouched", "failed cleanup does not follow symlink")
        try FileManager.default.removeItem(at: revocation.markerURL)
        check(relaunched.isRevoked, "preferences fallback retains revocation independently")
        switch AppleMusicSession.removeCredentialAfterDisconnect(at: file, revocationRecorded: false) {
        case .failure(.revocationPersistenceFailed): checks += 1
        default: fatalError("unrecorded cleanup failure reported success")
        }
        try FileManager.default.removeItem(at: file)
        _ = try AppleMusicCookieFile.write(cookie, to: file)
        try revocation.clearAfterExplicitAuthentication()
        check(!relaunched.isRevoked, "explicit reauthentication clears both markers")
        switch AppleMusicSession.removeCredentialAfterDisconnect(at: file, revocationRecorded: true) {
        case .success: checks += 1
        default: fatalError("successful cleanup reported failure")
        }
        check(!FileManager.default.fileExists(atPath: file.path), "success requires credential file absent")

        check(AppleMusicSession.isAllowed(URL(string: "https://music.apple.com/sg/browse")!), "music navigation allowed")
        check(AppleMusicSession.isAllowed(URL(string: "https://idmsa.apple.com/appleauth/auth/authorize")!), "official auth navigation allowed")
        check(!AppleMusicSession.isAllowed(URL(string: "https://apple.com.evil.example/")!), "lookalike navigation blocked")
        check(!AppleMusicSession.isAllowed(URL(string: "http://music.apple.com/")!), "insecure navigation blocked")
        check(!AppleMusicSession.isAllowed(URL(string: "https://user:pass@music.apple.com/")!), "URL credentials blocked")
        check(!AppleMusicSession.isAllowed(URL(string: "https://music.apple.com:8443/")!), "unexpected port blocked")
        check(AppleMusicSession.storefrontHomeURL("SG")?.absoluteString == "https://music.apple.com/sg/home", "verified storefront home uses normalized region")
        check(AppleMusicSession.storefrontHomeURL("../us") == nil, "invalid storefront path rejected")
        check(AppleMusicSession.storefrontHomeURL(nil) == nil, "missing storefront preserves default")
        print("PASS: \(checks) synthetic cookie-storage and navigation checks; no real credentials accessed.")
    }

    static func makeCookie(domain: String = ".music.apple.com", value: String = "synthetic-unit-test-token", expiry: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: "media-user-token", .value: value, .domain: domain, .path: "/", .secure: "TRUE",
            HTTPCookiePropertyKey(rawValue: "HttpOnly"): "TRUE"
        ]
        if let expiry { properties[.expires] = expiry }
        return HTTPCookie(properties: properties)!
    }

    static func check(_ condition: Bool, _ name: String) {
        guard condition else { fatalError("FAIL: \(name)") }
        checks += 1
    }
}
