import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI
import WebKit

// Only the minimal music service cookie crosses the web/native boundary.
// No JavaScript injection, DOM inspection, password handling or credential logging.
enum AppleMusicCookieFile {
    enum StorageError: Error { case invalid, unsafePath, unavailable }
    static let cookieName = "media-user-token"

    static func isValid(_ cookie: HTTPCookie, now: Date = Date()) -> Bool {
        let domain = cookie.domain.lowercased()
        guard ["music.apple.com", ".music.apple.com"].contains(domain),
              cookie.name == cookieName, !cookie.value.isEmpty,
              cookie.value.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 && $0 != ";" }),
              cookie.path.hasPrefix("/"), !cookie.path.contains("\t"),
              !cookie.path.contains("\n"), !cookie.path.contains("\r") else { return false }
        if let expiry = cookie.expiresDate {
            let seconds = expiry.timeIntervalSince1970
            return expiry > now && seconds.isFinite && seconds < Double(Int64.max)
        }
        return true
    }

    static func read(from url: URL, now: Date = Date()) throws -> HTTPCookie? {
        try rejectSymlinks(url)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw StorageError.unavailable
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= 2_000_000,
              let bytes = try handle.readToEnd(),
              let content = String(data: bytes, encoding: .utf8) else { throw StorageError.invalid }
        let lines = content.replacingOccurrences(of: "\u{feff}", with: "").components(separatedBy: .newlines)
        guard lines.prefix(3).contains(where: { $0.contains("Cookie File") }) else { throw StorageError.invalid }
        var result: HTTPCookie?
        for original in lines {
            let httpOnly = original.hasPrefix("#HttpOnly_")
            let line = httpOnly ? String(original.dropFirst(10)) : original
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 7, fields[5] == cookieName,
                  ["music.apple.com", ".music.apple.com"].contains(fields[0].lowercased()) else { continue }
            guard ["TRUE", "FALSE"].contains(fields[1]), ["TRUE", "FALSE"].contains(fields[3]),
                  let seconds = Int64(fields[4]), seconds >= 0 else { continue }
            if seconds != 0 && Double(seconds) <= now.timeIntervalSince1970 { continue }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: cookieName, .value: fields[6], .domain: fields[0].lowercased(),
                .path: fields[2], .version: "0"
            ]
            if fields[1] == "TRUE" { properties[.domain] = ".music.apple.com" }
            if fields[3] == "TRUE" { properties[.secure] = "TRUE" }
            if httpOnly { properties[HTTPCookiePropertyKey(rawValue: "HttpOnly")] = "TRUE" }
            if seconds != 0 { properties[.expires] = Date(timeIntervalSince1970: Double(seconds)) }
            if let cookie = HTTPCookie(properties: properties), isValid(cookie, now: now) { result = cookie }
        }
        return result
    }

    static func serialized(_ cookie: HTTPCookie) throws -> Data {
        guard isValid(cookie) else { throw StorageError.invalid }
        // A session cookie has no invented persistent expiry; Netscape uses zero.
        let expiry = cookie.isSessionOnly ? 0 : (cookie.expiresDate.map { Int64(floor($0.timeIntervalSince1970)) } ?? 0)
        let domain = (cookie.isHTTPOnly ? "#HttpOnly_" : "") + cookie.domain.lowercased()
        let fields = [domain, cookie.domain.hasPrefix(".") ? "TRUE" : "FALSE", cookie.path,
                      cookie.isSecure ? "TRUE" : "FALSE", String(expiry), cookieName, cookie.value]
        return Data(("# Netscape HTTP Cookie File\n" + fields.joined(separator: "\t") + "\n").utf8)
    }

    @discardableResult static func write(_ cookie: HTTPCookie, to url: URL) throws -> Bool {
        let data = try serialized(cookie)
        try rejectSymlinks(url)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try rejectSymlinks(url)
        guard chmod(parent.path, 0o700) == 0 else { throw StorageError.unavailable }
        if let old = try? read(from: url), let previous = try? serialized(old), previous == data {
            guard chmod(url.path, 0o600) == 0 else { throw StorageError.unavailable }
            return false
        }
        try writePrivateData(data, to: url)
        return true
    }

    fileprivate static func writePrivateData(_ data: Data, to url: URL) throws {
        try rejectSymlinks(url)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try rejectSymlinks(url)
        guard chmod(parent.path, 0o700) == 0 else { throw StorageError.unavailable }
        let temporary = parent.appendingPathComponent(".cookies-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw StorageError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        guard fchmod(descriptor, 0o600) == 0 else { throw StorageError.unavailable }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        try rejectSymlinks(url)
        guard rename(temporary.path, url.path) == 0 else { throw StorageError.unavailable }
    }

    static func remove(at url: URL) throws {
        try rejectSymlinks(url)
        if unlink(url.path) != 0 && errno != ENOENT { throw StorageError.unavailable }
    }

    private static func rejectSymlinks(_ url: URL) throws {
        for candidate in [url.deletingLastPathComponent(), url] {
            var info = stat()
            if lstat(candidate.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK {
                throw StorageError.unsafePath
            }
        }
    }
}

// The marker contains no credential. It sits outside the private cookie folder
// so a failure to remove a file in that folder does not re-enable it at launch.
// A preferences copy is an independent fallback if the app support folder is
// unwritable. Tests inject a separate, temporary preferences suite.
struct AppleMusicCredentialRevocation {
    let markerURL: URL
    private let defaults: UserDefaults
    private let key: String

    init(cookieURL: URL, defaults: UserDefaults = .standard) {
        markerURL = cookieURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".apple-music-login-revoked")
        self.defaults = defaults
        key = "AppleMusicLocal.revoked." + Data(cookieURL.standardizedFileURL.path.utf8).base64EncodedString()
    }

    var isRevoked: Bool {
        if defaults.bool(forKey: key) { return true }
        var info = stat()
        if lstat(markerURL.path, &info) == 0 { return true }
        return errno != ENOENT && errno != ENOTDIR
    }

    @discardableResult func record() -> Bool {
        defaults.set(true, forKey: key)
        let preferencesSaved = defaults.synchronize()
        do {
            try AppleMusicCookieFile.writePrivateData(Data("revoked\n".utf8), to: markerURL)
            return true
        } catch { return preferencesSaved }
    }

    func clearAfterExplicitAuthentication() throws {
        try AppleMusicCookieFile.remove(at: markerURL)
        defaults.removeObject(forKey: key)
        guard defaults.synchronize(), !isRevoked else {
            record()
            throw AppleMusicCookieFile.StorageError.unavailable
        }
    }
}

@MainActor
final class AppleMusicSession: NSObject, ObservableObject {
    enum DisconnectError: LocalizedError, Equatable {
        case credentialRemovalFailed, revocationPersistenceFailed
        var errorDescription: String? {
            switch self {
            case .credentialRemovalFailed:
                return "网页会话已清除，但本地登录文件未能删除。旧登录已标记撤销，不会自动恢复；请检查数据目录权限后重试。"
            case .revocationPersistenceFailed:
                return "网页会话已清除，但本地登录文件和撤销记录均未能处理。请检查数据目录权限并重试退出，当前登录不会在本次运行中继续使用。"
            }
        }
    }
    let cookieURL: URL
    let webView: WKWebView
    @Published var loading = false
    @Published var message = "请在 Apple 官方页面登录。"
    @Published var currentURL = "https://music.apple.com/"
    @Published var connected = false
    @Published private(set) var credentialsRevoked = false
    var onCredentialUpdate: (() -> Void)?
    var onCredentialRemoved: (() -> Void)?

    private let dataStore: WKWebsiteDataStore
    private let revocation: AppleMusicCredentialRevocation
    private var homeURL = URL(string: "https://music.apple.com/")!
    private var prepared = false
    private var hasLoaded = false
    private var requestedURL: URL?
    private var epoch: UInt64 = 0
    private var cookieRead: UInt64 = 0
    private var storeWrites = 0
    private var disconnecting = false
    private var clearingData = false
    private var disconnectNavigation: WKNavigation?
    private var waitingForBlankPage = false
    private var disconnectCallbacks: [(Result<Void, DisconnectError>) -> Void] = []
    private var revocationRecorded = false
    private var acceptFreshCookies = false
    private var expirationTask: DispatchWorkItem?
    private var urlObservation: NSKeyValueObservation?
    private var popupWindows: [ObjectIdentifier: (NSWindow, WKWebView)] = [:]

    init(cookieURL: URL) {
        self.cookieURL = cookieURL
        revocation = AppleMusicCredentialRevocation(cookieURL: cookieURL)
        dataStore = .default()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        credentialsRevoked = revocation.isRevoked
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] view, _ in
            Task { @MainActor in self?.updateDisplayedURL(view) }
        }
        dataStore.httpCookieStore.add(self)
        prepareSession()
    }

    func loadIfNeeded() {
        guard !disconnecting, !hasLoaded else { return }
        if requestedURL == nil { requestedURL = homeURL }
        loadRequestedPage()
    }

    func reload() {
        guard !disconnecting else { return }
        if prepared, hasLoaded, let url = webView.url, Self.isAllowed(url) {
            webView.reload()
        } else { goHome() }
    }

    func goHome() { openURL(homeURL) }

    func setStorefront(_ code: String?) {
        guard let url = Self.storefrontHomeURL(code) else { return }
        let previousHome = homeURL
        homeURL = url
        if !hasLoaded {
            if requestedURL == previousHome { requestedURL = url }
            if requestedURL == nil || requestedURL == url { currentURL = url.absoluteString }
        }
    }

    static func storefrontHomeURL(_ code: String?) -> URL? {
        guard let code = code?.lowercased(), code.utf8.count == 2,
              code.utf8.allSatisfy({ (97...122).contains($0) }) else { return nil }
        return URL(string: "https://music.apple.com/\(code)/home")
    }

    func openURL(_ url: URL) {
        guard Self.isAllowed(url), !disconnecting else {
            if !disconnecting { message = "此窗口仅打开 Apple 官方 HTTPS 页面。" }
            return
        }
        requestedURL = url
        loadRequestedPage()
    }

    // An explicit manual import must win over an older cookie in the web store.
    func refreshSavedCredential() {
        guard !disconnecting else { return }
        epoch &+= 1
        cookieRead &+= 1
        guard let saved = try? AppleMusicCookieFile.read(from: cookieURL) else {
            message = "本地登录信息无效或已过期，请重新登录。"
            return
        }
        // The caller invokes this only after an explicit manual import succeeds.
        do { try revocation.clearAfterExplicitAuthentication() }
        catch { message = "无法更新本地撤销记录，请检查数据目录权限。"; return }
        credentialsRevoked = false
        acceptFreshCookies = false
        prepared = false
        restore(saved, generation: epoch, replacingExisting: true)
    }

    func disconnect(completion: @escaping (Result<Void, DisconnectError>) -> Void) {
        disconnectCallbacks.append(completion)
        guard !disconnecting else { return }
        disconnecting = true
        credentialsRevoked = true
        acceptFreshCookies = false
        revocationRecorded = revocation.record()
        epoch &+= 1
        cookieRead &+= 1
        dataStore.httpCookieStore.remove(self)
        expirationTask?.cancel()
        expirationTask = nil
        requestedURL = nil
        webView.stopLoading()
        for (window, popup) in Array(popupWindows.values) { popup.stopLoading(); window.close() }
        loading = false
        connected = false
        message = "正在移除此应用中的登录信息…"
        // Destroy the old page's JS context before clearing cookies; stopLoading
        // alone does not stop timers in an already-loaded authentication page.
        waitingForBlankPage = true
        disconnectNavigation = webView.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        if disconnectNavigation == nil { waitingForBlankPage = false }
        // Wait for already-issued setCookie completions before clearing the store.
        finishDisconnectIfReady()
    }

    private func prepareSession() {
        let generation = epoch
        if credentialsRevoked {
            // A revoked file is never restored, including after an interrupted
            // or partially failed disconnect. Clear any persisted browser copy
            // before accepting a newly entered login on a fresh official page.
            dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
                Task { @MainActor in
                    guard let self, self.epoch == generation, !self.disconnecting else { return }
                    self.prepared = true
                    self.acceptFreshCookies = true
                    self.connected = false
                    self.message = "此前登录已撤销，请在 Apple 官方页面重新登录。"
                    self.loadRequestedPage()
                }
            }
            return
        }
        dataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self, self.epoch == generation, !self.disconnecting else { return }
                if Self.preferredCookie(cookies) != nil {
                    self.prepared = true
                    self.apply(cookies, notify: false)
                    self.loadRequestedPage()
                } else if let saved = try? AppleMusicCookieFile.read(from: self.cookieURL) {
                    self.restore(saved, generation: generation)
                } else {
                    self.prepared = true
                    self.apply(cookies, notify: false)
                    self.loadRequestedPage()
                }
            }
        }
    }

    private func restore(_ cookie: HTTPCookie, generation: UInt64, replacingExisting: Bool = false) {
        storeWrites += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.storeWrites -= 1
                if self.disconnecting { self.finishDisconnectIfReady() }
                else if self.epoch == generation {
                    self.prepared = true
                    // Restoring existing credentials is not a new login event.
                    self.synchronizeCookies(notify: false)
                    self.loadRequestedPage()
                }
            }
            let store = self.dataStore.httpCookieStore
            if replacingExisting {
                let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
                    store.getAllCookies { continuation.resume(returning: $0) }
                }
                guard self.epoch == generation, !self.disconnecting else { return }
                let previous = cookies.filter {
                    $0.name == AppleMusicCookieFile.cookieName &&
                    ["music.apple.com", ".music.apple.com"].contains($0.domain.lowercased())
                }
                for old in previous {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        store.delete(old) { continuation.resume() }
                    }
                    guard self.epoch == generation, !self.disconnecting else { return }
                }
            }
            guard self.epoch == generation, !self.disconnecting else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.setCookie(cookie) { continuation.resume() }
            }
        }
    }

    private func loadRequestedPage() {
        guard prepared, !disconnecting, let url = requestedURL else { return }
        requestedURL = nil
        hasLoaded = true
        webView.load(URLRequest(url: url))
    }

    private func synchronizeCookies(notify: Bool = true) {
        guard prepared, !disconnecting, storeWrites == 0 else { return }
        let generation = epoch
        cookieRead &+= 1
        let request = cookieRead
        dataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self, self.epoch == generation, self.cookieRead == request,
                      !self.disconnecting, self.storeWrites == 0 else { return }
                self.apply(cookies, notify: notify)
            }
        }
    }

    private func apply(_ cookies: [HTTPCookie], notify: Bool) {
        guard !disconnecting else { return }
        guard !credentialsRevoked || acceptFreshCookies else { return }
        let previouslyConnected = connected
        expirationTask?.cancel()
        expirationTask = nil
        if let cookie = Self.preferredCookie(cookies) {
            do {
                let changed = try AppleMusicCookieFile.write(cookie, to: cookieURL)
                if credentialsRevoked {
                    try revocation.clearAfterExplicitAuthentication()
                    credentialsRevoked = false
                    acceptFreshCookies = false
                }
                connected = true
                message = "登录信息已保存在本机；会员权限需单独验证。"
                if let expiry = cookie.expiresDate {
                    let task = DispatchWorkItem { [weak self] in
                        Task { @MainActor in self?.synchronizeCookies() }
                    }
                    expirationTask = task
                    DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, expiry.timeIntervalSinceNow + 0.05), execute: task)
                }
                if notify && (changed || !previouslyConnected) { onCredentialUpdate?() }
            } catch {
                connected = false
                message = "无法安全保存登录信息，请检查此应用的数据目录权限。"
                if notify && previouslyConnected { onCredentialRemoved?() }
            }
        } else {
            connected = false
            if credentialsRevoked { return }
            do { try AppleMusicCookieFile.remove(at: cookieURL) }
            catch { message = "无法移除本地登录文件，请检查数据目录权限。"; return }
            message = previouslyConnected ? "登录信息已失效，请在 Apple 页面重新登录。" : "请在 Apple 官方页面登录。"
            if notify && previouslyConnected { onCredentialRemoved?() }
        }
    }

    private func finishDisconnectIfReady() {
        guard disconnecting, storeWrites == 0, !waitingForBlankPage, !clearingData else { return }
        clearingData = true
        dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let result = Self.removeCredentialAfterDisconnect(at: self.cookieURL, revocationRecorded: self.revocationRecorded)
                self.prepared = true
                self.hasLoaded = false
                self.connected = false
                self.clearingData = false
                self.disconnecting = false
                self.acceptFreshCookies = true
                self.disconnectNavigation = nil
                self.currentURL = self.homeURL.absoluteString
                switch result {
                case .success: self.message = "已移除此应用中的 Apple Music 登录信息。"
                case .failure(let error): self.message = error.localizedDescription
                }
                self.dataStore.httpCookieStore.add(self)
                self.onCredentialRemoved?()
                let callbacks = self.disconnectCallbacks
                self.disconnectCallbacks.removeAll()
                callbacks.forEach { $0(result) }
            }
        }
    }

    static func removeCredentialAfterDisconnect(at url: URL, revocationRecorded: Bool) -> Result<Void, DisconnectError> {
        do { try AppleMusicCookieFile.remove(at: url); return .success(()) }
        catch { return .failure(revocationRecorded ? .credentialRemovalFailed : .revocationPersistenceFailed) }
    }

    private static func preferredCookie(_ cookies: [HTTPCookie]) -> HTTPCookie? {
        let valid = cookies.filter { AppleMusicCookieFile.isValid($0) }
        return valid.first(where: { $0.path == "/" }) ?? valid.first
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        return host == "apple.com" || host.hasSuffix(".apple.com")
    }

    private func updateDisplayedURL(_ view: WKWebView) {
        guard view === webView, let url = view.url, Self.isAllowed(url),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        // OAuth query/fragment values never enter observable UI state.
        components.query = nil
        components.fragment = nil
        currentURL = components.string ?? "https://music.apple.com/"
    }
}

extension AppleMusicSession: WKHTTPCookieStoreObserver {
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { synchronizeCookies() }
}

extension AppleMusicSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.request.url?.absoluteString == "about:blank" {
            decisionHandler(.allow); return
        }
        guard !disconnecting else { decisionHandler(.cancel); return }
        if let url = navigationAction.request.url,
           Self.isAllowed(url) || url.absoluteString == "about:blank" {
            decisionHandler(.allow)
        } else {
            message = "此窗口仅打开 Apple 官方 HTTPS 页面。"
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.response.url?.absoluteString == "about:blank" {
            decisionHandler(.allow); return
        }
        guard !disconnecting, let url = navigationResponse.response.url,
              Self.isAllowed(url) || url.absoluteString == "about:blank" else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === self.webView { loading = true; updateDisplayedURL(webView) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView { loading = false; updateDisplayedURL(webView) }
        if disconnecting, webView === self.webView, navigation === disconnectNavigation {
            waitingForBlankPage = false
            finishDisconnectIfReady()
            return
        }
        synchronizeCookies()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(webView, navigation: navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(webView, navigation: navigation, error: error)
    }

    private func navigationFailed(_ view: WKWebView, navigation: WKNavigation?, error: Error) {
        if view === webView { loading = false }
        if disconnecting, view === webView, navigation === disconnectNavigation {
            waitingForBlankPage = false
            finishDisconnectIfReady()
            return
        }
        guard !disconnecting, (error as NSError).code != NSURLErrorCancelled else { return }
        message = "Apple 页面暂时无法打开，请检查网络后重试。"
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === self.webView { loading = false }
        if disconnecting, webView === self.webView {
            waitingForBlankPage = false
            finishDisconnectIfReady()
            return
        }
        message = "网页登录进程已停止，请刷新页面继续。"
    }
}

extension AppleMusicSession: WKUIDelegate, NSWindowDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !disconnecting, navigationAction.targetFrame == nil,
              let url = navigationAction.request.url,
              Self.isAllowed(url) || url.absoluteString == "about:blank" else { return nil }
        // Use WebKit's supplied configuration so the popup retains window.opener.
        configuration.websiteDataStore = dataStore
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Apple 账户登录"
        window.isReleasedWhenClosed = false
        window.contentView = popup
        window.delegate = self
        popupWindows[ObjectIdentifier(window)] = (window, popup)
        window.center()
        window.makeKeyAndOrderFront(nil)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let (window, _) = popupWindows.values.first(where: { $0.1 === webView }) { window.close() }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let (_, popup) = popupWindows.removeValue(forKey: ObjectIdentifier(window)) else { return }
        popup.stopLoading()
        popup.uiDelegate = nil
        popup.navigationDelegate = nil
        synchronizeCookies()
    }
}

struct AppleMusicWebView: NSViewRepresentable {
    let session: AppleMusicSession
    func makeNSView(context: Context) -> WKWebView { session.loadIfNeeded(); return session.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
