import AppKit
import Foundation

// The runner compiles the real Model.swift with only its storage-root assignment
// redirected into a fresh temporary directory. These stubs never start a process,
// load a web view, access credentials, or communicate with a service.
@MainActor
enum ModelTestSandbox {
    static func newSupportURL() -> URL {
        guard let root = ProcessInfo.processInfo.environment["MUSICLOCAL_TEST_ROOT"],
              root.contains("music-local-model.") else {
            fatalError("Run through run-model-state-tests.sh with an isolated test root")
        }
        return URL(fileURLWithPath: root).appendingPathComponent(UUID().uuidString)
    }
}

@MainActor
final class BackendRunner {
    static var calls: [BackendRunner] = []
    private(set) var request: [String: Any] = [:]
    private(set) var cancelled = false
    private var onEvent: (([String: Any]) -> Void)?
    private var onExit: ((Int32) -> Void)?

    func start(_ request: [String: Any], onEvent: @escaping ([String: Any]) -> Void,
               onExit: @escaping (Int32) -> Void) throws {
        self.request = request; self.onEvent = onEvent; self.onExit = onExit
        Self.calls.append(self)
    }
    func cancel() { cancelled = true }
    // Cancelled operations deliberately retain callbacks to exercise stale replies.
    func event(_ value: [String: Any]) { onEvent?(value) }
    func exit(_ code: Int32 = 0) { let callback = onExit; onExit = nil; callback?(code) }
    static func matching(_ command: String) -> [BackendRunner] {
        calls.filter { $0.request["command"] as? String == command }
    }
    static func last(_ command: String) throws -> BackendRunner {
        guard let call = matching(command).last else { throw TestFailure("Missing backend command: \(command)") }
        return call
    }
}

@MainActor
final class AppleMusicSession {
    enum DisconnectError: Error, LocalizedError {
        case credentialRemoval
        var errorDescription: String? { "Synthetic credential removal failed" }
    }
    let cookieURL: URL
    var credentialsRevoked = false
    var onCredentialUpdate: (() -> Void)?
    var onCredentialRemoved: (() -> Void)?
    private var disconnectCompletion: ((Result<Void, DisconnectError>) -> Void)?
    init(cookieURL: URL) { self.cookieURL = cookieURL }
    func loadIfNeeded() {}
    func openURL(_ url: URL) {}
    func setStorefront(_ code: String?) {}
    func refreshSavedCredential() {}
    func disconnect(completion: @escaping (Result<Void, DisconnectError>) -> Void) {
        credentialsRevoked = true; disconnectCompletion = completion
    }
    func finishDisconnect(removed: Bool = true) {
        let callback = disconnectCompletion; disconnectCompletion = nil
        callback?(removed ? .success(()) : .failure(.credentialRemoval))
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@main
@MainActor
struct ModelStateTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(message) }
    }

    static func model() -> DownloadModel {
        BackendRunner.calls = []
        let root = ProcessInfo.processInfo.environment["MUSICLOCAL_TEST_ROOT"]!
        // A volatile domain shadows preferences without writing a preferences file.
        UserDefaults.standard.setVolatileDomain([
            "format": "mp3", "outputPath": root + "/downloads"
        ], forName: UserDefaults.argumentDomain)
        let result = DownloadModel()
        precondition(result.supportURL.path.hasPrefix(root + "/"))
        precondition(result.cookieURL.path.hasPrefix(root + "/"))
        result.engineReady = true
        result.cookieReady = true
        result.accountState = "connected"
        result.accountRegion = "us"
        return result
    }

    static func job(_ number: Int, in model: DownloadModel) -> DownloadJob {
        DownloadJob(url: "https://music.apple.com/us/song/test/\(number)",
                    title: "Synthetic \(number)", directory: model.outputPath)
    }

    static func page(_ id: String, region: String, more: Bool) -> [String: Any] {
        ["event": "done", "status": "completed", "storefront": region,
         "storefront_source": "account", "has_more": more, "next_offset": 25,
         "results": [["id": id, "kind": "songs", "title": "Synthetic \(id)",
                      "url": "https://music.apple.com/\(region)/song/test/\(id)"]]]
    }

    static func staleStatusAfterLogout() throws {
        let model = model()
        model.checkCookies()
        let oldStatus = try BackendRunner.last("auth_status")
        model.disconnectAccount()
        try expect(model.signingOut && !model.cookieReady, "Logout must invalidate readiness immediately")
        oldStatus.event(["event": "done", "valid": true])
        try expect(!model.cookieReady, "Late auth status restored readiness during logout")
        model.session.finishDisconnect()
        oldStatus.event(["event": "done", "valid": true])
        oldStatus.exit()
        try expect(!model.cookieReady && model.accountState == "missing", "Late auth status restored a logged-out account")
        try expect(BackendRunner.matching("verify_account").isEmpty, "Stale auth status triggered account verification")
    }

    static func downloadDuringLogout() throws {
        let model = model()
        model.jobs = [job(101, in: model)]
        model.signingOut = true
        // Keep readiness true to check the central signingOut guard independently.
        model.cookieReady = true
        model.startQueue()
        try expect(!model.isRunning, "A batch started while logout was in progress")
        try expect(model.jobs[0].status == "pending", "Logout changed a waiting job")
        try expect(BackendRunner.matching("download").isEmpty, "A download worker started during logout")
    }

    static func failedLogoutStaysRevoked() throws {
        let model = model()
        model.jobs = [job(101, in: model)]
        model.disconnectAccount()
        model.session.finishDisconnect(removed: false)
        try expect(!model.signingOut && !model.cookieReady && model.errorMessage != nil,
                   "Failed credential deletion was reported as a successful logout")
        // Exercise all model gates despite an unrelated stale readiness flag.
        model.cookieReady = true
        model.checkCookies()
        try expect(!model.cookieReady, "Status check retained readiness for revoked credentials")
        model.cookieReady = true; model.verifyAccount()
        model.cookieReady = true; model.startQueue()
        try expect(!model.isRunning, "Revoked credentials became usable after failed logout")
        try expect(BackendRunner.matching("auth_status").isEmpty
                   && BackendRunner.matching("verify_account").isEmpty
                   && BackendRunner.matching("download").isEmpty,
                   "A worker was allowed to reuse revoked credentials")
    }

    static func storefrontMismatch() throws {
        let model = model()
        model.searchText = "Synthetic search"
        model.search()
        let first = try BackendRunner.last("search")
        first.event(page("101", region: "us", more: true)); first.exit()
        model.selectedResults = ["101"]
        model.search(loadMore: true)
        let second = try BackendRunner.last("search")
        try expect(second !== first && second.request["offset"] as? Int == 25, "Next-page request was not issued")
        second.event(page("202", region: "tw", more: true)); second.exit()
        try expect(model.results.map(\.id) == ["101"], "A page from another storefront was appended")
        try expect(model.searchRegion == "us", "Storefront changed beneath existing results")
        try expect(model.selectedResults == ["101"], "Rejected page changed selection")
        try expect(!model.searchHasMore && !model.searching && !model.searchMessage.isEmpty,
                   "Rejected page did not finish with a recoverable message")
    }

    static func credentialChangeStopsBatch(removed: Bool) throws {
        let model = model()
        model.jobs = [job(101, in: model), job(202, in: model)]
        model.startQueue()
        let running = try BackendRunner.last("download")
        if removed { model.session.onCredentialRemoved?() }
        else { model.session.onCredentialUpdate?() }
        try expect(running.cancelled && model.stopping, "Credential change did not cancel the current worker")
        running.event(["event": "done", "status": "cancelled", "files": [String](), "output": ""])
        running.exit(1)
        try expect(!model.isRunning, "Credential change left the batch running")
        try expect(model.jobs[1].status == "pending", "Next job was processed after account change")
        try expect(BackendRunner.matching("download").count == 1, "A second download began after account change")
        if removed { try expect(!model.cookieReady, "Credential removal retained readiness") }
    }

    static func perResultDownloadScope() throws {
        let model = model()
        model.jobs = [job(101, in: model)]
        let requested = CatalogItem(["id": "202", "kind": "songs", "title": "Requested song",
                                     "url": "https://music.apple.com/us/song/test/202"])!
        model.addCatalogItems([requested], begin: true)
        let running = try BackendRunner.last("download")
        try expect(running.request["url"] as? String == requested.url, "Per-result Download started another queued item")
        try expect(model.jobs[0].status == "pending" && model.batchTotal == 1, "Per-result Download included unrelated jobs")
        running.event(["event": "done", "status": "completed", "files": [String](), "output": ""])
        running.exit()
        try expect(!model.isRunning && model.jobs[0].status == "pending", "Per-result batch continued into unrelated jobs")
        try expect(BackendRunner.matching("download").count == 1, "Unexpected extra worker for a per-result request")
    }

    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("stale auth_status after logout", staleStatusAfterLogout),
            ("download start while signing out", downloadDuringLogout),
            ("failed logout keeps credentials revoked", failedLogoutStaysRevoked),
            ("different-storefront next page", storefrontMismatch),
            ("credential change stops active batch", { try credentialChangeStopsBatch(removed: false) }),
            ("credential removal stops active batch", { try credentialChangeStopsBatch(removed: true) }),
            ("per-result download scopes requested IDs", perResultDownloadScope)
        ]
        var failed = 0
        for (name, test) in tests {
            do { try test(); print("PASS: \(name)") }
            catch { failed += 1; print("FAIL: \(name): \(error)") }
        }
        print("Model state regressions: \(tests.count - failed)/\(tests.count) passed (synthetic; no account/network access).")
        Darwin.exit(failed == 0 ? 0 : 1)
    }
}
