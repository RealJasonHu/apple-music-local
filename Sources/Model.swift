import AppKit
import SwiftUI

struct DownloadJob: Identifiable, Codable {
    var id = UUID().uuidString
    var url: String
    var title: String
    var status = "pending"
    var message = "等待下载"
    var completed = 0
    var total = 0
    var format = "mp3"
    var directory = ""
    var output = ""
    var files: [String] = []
    var created = Date()

    var statusName: String {
        ["pending": "等待中", "running": "下载中", "completed": "已完成", "failed": "失败",
         "partial": "部分完成", "cancelled": "已停止"][status] ?? status
    }
}

struct SavedState: Codable { var jobs: [DownloadJob] }

struct CatalogItem: Identifiable {
    let id: String
    let kind: String
    let title: String
    let artist: String
    let album: String
    let url: String
    let artworkURL: URL?
    let duration: Int
    let tracks: Int
    let explicit: Bool
    init?(_ record: [String: Any]) {
        guard let id = record["id"] as? String, let url = record["url"] as? String,
              !DownloadModel.parseLinks(url).links.isEmpty else { return nil }
        self.id = id; self.url = url
        kind = record["kind"] as? String ?? "songs"
        title = record["title"] as? String ?? "未命名"
        artist = record["artist"] as? String ?? ""
        album = record["album"] as? String ?? ""
        artworkURL = (record["artwork_url"] as? String).flatMap(URL.init(string:))
        duration = record["duration_ms"] as? Int ?? 0
        tracks = record["track_count"] as? Int ?? 0
        explicit = record["explicit"] as? Bool ?? false
    }
}

@MainActor
final class DownloadModel: ObservableObject {
    @Published var linkText = ""
    @Published var jobs: [DownloadJob] = []
    @Published var selection = "search"
    @Published var selectedFormat: String {
        didSet { UserDefaults.standard.set(selectedFormat, forKey: "format"); updatePendingOptions() }
    }
    @Published var outputPath: String {
        didSet { UserDefaults.standard.set(outputPath, forKey: "outputPath"); updatePendingOptions() }
    }
    @Published var cookieReady = false
    @Published var importing = false
    @Published var engineReady = false
    @Published var engineMessage = "正在检查下载组件…"
    @Published var isRunning = false
    @Published var stopping = false
    @Published var notice = ""
    @Published var errorMessage: String?
    @Published var showHelp = false
    @Published var accountState = "checking"
    @Published var accountMessage = "正在检查已保存的登录…"
    @Published var accountRegion = ""
    @Published var verifyingAccount = false
    @Published var signingOut = false
    @Published var searchText = ""
    @Published var searchKind = "songs"
    @Published var results: [CatalogItem] = []
    @Published var selectedResults: Set<String> = []
    @Published var searching = false
    @Published var searched = false
    @Published var searchMessage = ""
    @Published var searchRegion = ""
    @Published var searchPublic = false
    @Published var searchHasMore = false
    private var nextOffset = 0
    private var submittedQuery = ""
    private var submittedKind = "songs"
    private var queryGeneration = UUID()
    private var accountGeneration = UUID()
    private var verificationGeneration = UUID()
    private var accountRunner: BackendRunner?
    private var searchRunner: BackendRunner?
    private var lastAccountCheck = Date.distantPast
    let session: AppleMusicSession
    private var runner: BackendRunner?
    private var setupRunner: BackendRunner?
    private var currentID: String?
    private var stopRequested = false
    private var batchIDs: Set<String> = []
    private var finalReceived = false
    let supportURL: URL
    let cookieURL: URL

    init() {
        supportURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Apple Music Local")
        cookieURL = supportURL.appendingPathComponent("private/cookies.txt")
        session = AppleMusicSession(cookieURL: cookieURL)
        let savedFormat = UserDefaults.standard.string(forKey: "format") ?? "mp3"
        selectedFormat = ["mp3", "wav", "aac"].contains(savedFormat) ? savedFormat : "mp3"
        outputPath = UserDefaults.standard.string(forKey: "outputPath") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        if let data = try? Data(contentsOf: supportURL.appendingPathComponent("queue.json")),
           let saved = try? JSONDecoder().decode(SavedState.self, from: data) {
            jobs = saved.jobs.map { original in
                var job = original
                if job.status == "running" { job.status = "pending"; job.message = "上次任务被中断，可重新开始" }
                return job
            }
        }
        session.onCredentialUpdate = { [weak self] in self?.credentialChanged() }
        session.onCredentialRemoved = { [weak self] in self?.credentialRemoved() }
        checkEngine()
    }

    var pendingCount: Int { jobs.filter { $0.status == "pending" }.count }
    var completedCount: Int { jobs.filter { $0.status == "completed" }.count }
    var attentionCount: Int { jobs.filter { ["failed", "partial", "cancelled"].contains($0.status) }.count }
    var visibleJobs: [DownloadJob] {
        selection == "completed" ? jobs.filter { ["completed", "partial"].contains($0.status) } : jobs
    }
    var currentJob: DownloadJob? { jobs.first { $0.id == currentID } }
    var batchCompleted: Int { jobs.filter { batchIDs.contains($0.id) && !["pending", "running"].contains($0.status) }.count }
    var batchTotal: Int { batchIDs.count }
    var accountLabel: String {
        switch accountState {
        case "connected": return "Apple Music 已连接"
        case "checking": return "正在验证登录"
        case "expired": return "需要重新登录"
        case "no_subscription": return "未检测到有效订阅"
        case "offline": return "登录状态待验证"
        default: return "登录 Apple Music"
        }
    }
    var formatNote: String {
        switch selectedFormat {
        case "wav": return "AAC 音源转为 WAV，便于导入音频软件；转换不会提升源音质。"
        case "aac": return "保留 Apple Music 网页 AAC 256 kbps 音源，文件扩展名为 .m4a。"
        default: return "AAC 音源转为 MP3 320 kbps，兼容常见播放器。"
        }
    }

    nonisolated static func parseLinks(_ text: String) -> (links: [String], rejected: Int, duplicates: Int) {
        if text.contains("media-user-token") || text.contains("Netscape HTTP Cookie") { return ([], 1, 0) }
        let separator = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,；;"))
        let parts = text.components(separatedBy: separator).filter { !$0.isEmpty }
        var links: [String] = [], seen = Set<String>(), rejected = 0, duplicates = 0
        let trim = CharacterSet(charactersIn: "\"'<>[]()。")
        for raw in parts {
            let candidate = raw.trimmingCharacters(in: trim)
            guard candidate.count <= 4096, var url = URLComponents(string: candidate),
                  url.scheme?.lowercased() == "https", url.host?.lowercased() == "music.apple.com",
                  url.user == nil, url.password == nil, url.port == nil else {
                rejected += 1; continue
            }
            let path = url.path.split(separator: "/").map(String.init)
            guard path.count >= 3, path[0].count == 2,
                  path[0].unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) && $0.isASCII }),
                  ["song", "album", "playlist"].contains(path[1]),
                  !path.contains("."), !path.contains("..") else { rejected += 1; continue }
            url.scheme = "https"; url.host = "music.apple.com"; url.fragment = nil
            url.queryItems = url.queryItems?.filter { $0.name == "i" }
            if url.queryItems?.isEmpty == true { url.queryItems = nil }
            guard let normalized = url.string else { rejected += 1; continue }
            if seen.insert(normalized).inserted { links.append(normalized) } else { duplicates += 1 }
        }
        return (links, rejected, duplicates)
    }

    func guardCookiePaste() {
        if linkText.contains("media-user-token") || linkText.contains("Netscape HTTP Cookie") {
            linkText = ""
            errorMessage = "这里用于粘贴音乐链接。Cookie 请通过“账号与登录”中的“导入 Cookie 文件”选择导出的 .txt 文件；内容无需粘贴到输入框。"
        }
    }

    func pasteLinks() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            notice = "剪贴板里没有文字链接。"; return
        }
        linkText += (linkText.isEmpty ? "" : "\n") + text
        guardCookiePaste()
    }

    func enqueue() {
        let parsed = Self.parseLinks(linkText)
        guard !parsed.links.isEmpty else { errorMessage = "请输入 Apple Music 歌曲、专辑或歌单的 HTTPS 分享链接，每行一个。"; return }
        let active = Set(jobs.filter { ["pending", "running"].contains($0.status) }.map(\.url))
        let newLinks = parsed.links.filter { !active.contains($0) }
        for link in newLinks {
            let segments = URL(string: link)?.pathComponents ?? []
            let kind = segments.contains("playlist") ? "歌单" : segments.contains("album") ? "专辑 / 歌曲" : "歌曲"
            let slug = segments.count > 2 ? segments[segments.count - 2].removingPercentEncoding ?? "" : ""
            let title = ["song", "album", "playlist", "library"].contains(slug) || slug.isEmpty ? "Apple Music \(kind)" : slug.replacingOccurrences(of: "-", with: " ")
            jobs.append(DownloadJob(url: link, title: title, format: selectedFormat, directory: outputPath))
        }
        let skipped = parsed.duplicates + parsed.links.count - newLinks.count
        notice = "已添加 \(newLinks.count) 个链接" + (skipped > 0 ? " · 跳过 \(skipped) 个重复链接" : "") + (parsed.rejected > 0 ? " · 忽略 \(parsed.rejected) 项无效内容" : "")
        linkText = ""; selection = "queue"; persist()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择音乐保存位置"; panel.prompt = "选择此文件夹"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.directoryURL = URL(fileURLWithPath: outputPath)
        if panel.runModal() == .OK, let url = panel.url { outputPath = url.path }
    }

    func chooseCookies() {
        guard !signingOut, !importing, !isRunning else { return }
        let panel = NSOpenPanel()
        panel.title = "选择从 Apple Music 网页导出的 cookies.txt"
        panel.message = "选择文件即可，无需打开文件或粘贴内容。"
        panel.prompt = "导入 Cookie"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        if panel.runModal() == .OK, let url = panel.url { importCookies(url) }
    }

    func importCookies(_ source: URL) {
        importing = true
        let task = BackendRunner(); setupRunner = task
        var received = false
        do {
            try task.start(["command": "import_cookies", "source": source.path, "cookie_path": cookieURL.path], onEvent: { [weak self] event in
                guard let self, event["event"] as? String == "done" else { return }
                received = true
                if event["status"] as? String == "completed" {
                    self.cookieReady = true; self.notice = "Cookie 已导入，正在验证会员权限。"
                    self.session.refreshSavedCredential()
                    self.credentialChanged()
                } else { self.errorMessage = event["message"] as? String ?? "导入失败，请重新导出 Apple Music Cookie。" }
            }, onExit: { [weak self] _ in
                self?.importing = false; self?.setupRunner = nil
                if !received { self?.errorMessage = "凭据导入未完成，请重试。" }
            })
        } catch { importing = false; errorMessage = "无法启动导入组件：\(error.localizedDescription)" }
    }

    func checkEngine() {
        let task = BackendRunner(); setupRunner = task
        var received = false
        do {
            try task.start(["command": "self_test"], onEvent: { [weak self] event in
                guard let self, event["event"] as? String == "done" else { return }
                received = true
                self.engineReady = event["status"] as? String == "completed"
                self.engineMessage = self.engineReady ? "下载组件已就绪" : (event["message"] as? String ?? "组件检查失败")
            }, onExit: { [weak self] _ in
                guard let self else { return }
                if !received { self.engineMessage = "下载组件无法启动，请重新安装 App。" }
                self.setupRunner = nil
                self.checkCookies()
            })
        } catch { engineMessage = "找不到完整的运行组件，请重新安装 App。" }
    }

    func checkCookies() {
        guard !signingOut, !session.credentialsRevoked else { cookieReady = false; accountState = "missing"; return }
        let generation = accountGeneration
        let task = BackendRunner(); setupRunner = task
        try? task.start(["command": "auth_status", "cookie_path": cookieURL.path], onEvent: { [weak self] event in
            guard let self, self.accountGeneration == generation, !self.signingOut else { return }
            if event["event"] as? String == "done" { self.cookieReady = event["valid"] as? Bool ?? false }
        }, onExit: { [weak self] _ in
            guard let self, self.accountGeneration == generation, !self.signingOut else { return }
            self.setupRunner = nil
            if self.cookieReady { self.verifyAccount(force: true) }
            else { self.accountState = "missing"; self.accountMessage = "在 App 内登录，之后会自动保存会话。" }
        })
    }

    func openAccount() { session.setStorefront(accountRegion); selection = "account"; session.loadIfNeeded() }
    func openCatalogPage(_ item: CatalogItem) {
        guard let url = URL(string: item.url) else { return }
        selection = "account"; session.openURL(url)
    }
    func appBecameActive() { verifyAccount(force: false) }

    private func invalidateSearch() {
        queryGeneration = UUID(); searchRunner?.cancel(); searchRunner = nil
        searching = false; results = []; selectedResults = []; searchHasMore = false
        searched = false; searchMessage = ""
    }
    private func credentialChanged() {
        guard !signingOut else { return }
        if isRunning { stop() }
        accountGeneration = UUID(); cookieReady = true
        invalidateSearch(); verifyAccount(force: true)
    }
    private func credentialRemoved() {
        guard !signingOut else { return }
        if isRunning { stop() }
        accountGeneration = UUID(); accountRunner?.cancel(); verifyingAccount = false
        cookieReady = false; accountState = "missing"; accountRegion = ""
        accountMessage = "已退出登录，可以在 App 内重新登录。"
        invalidateSearch()
    }

    func verifyAccount(force: Bool = true) {
        guard engineReady, !signingOut, !session.credentialsRevoked, cookieReady,
              force || (!verifyingAccount && Date().timeIntervalSince(lastAccountCheck) > 300) else { return }
        accountRunner?.cancel()
        verificationGeneration = UUID(); let generation = verificationGeneration
        let account = accountGeneration
        verifyingAccount = true; lastAccountCheck = Date()
        if accountState != "connected" { accountState = "checking" }
        let task = BackendRunner(); accountRunner = task
        var received = false
        do {
            try task.start(["command": "verify_account", "cookie_path": cookieURL.path], onEvent: { [weak self] event in
                guard let self, self.verificationGeneration == generation, self.accountGeneration == account,
                      event["event"] as? String == "done" else { return }
                received = true
                self.accountMessage = event["message"] as? String ?? "登录验证已完成。"
                if event["authenticated"] as? Bool == true {
                    self.accountState = event["subscription"] as? Bool == true ? "connected" : "no_subscription"
                    let region = event["storefront"] as? String ?? ""
                    if !self.accountRegion.isEmpty && self.accountRegion != region { self.invalidateSearch() }
                    self.accountRegion = region
                    self.session.setStorefront(region)
                } else if event["auth_invalid"] as? Bool == true {
                    self.accountState = "expired"; self.cookieReady = false
                } else { self.accountState = "offline" }
            }, onExit: { [weak self] _ in
                guard let self, self.verificationGeneration == generation, self.accountGeneration == account else { return }
                self.verifyingAccount = false; self.accountRunner = nil
                if !received { self.accountState = "offline"; self.accountMessage = "暂时无法验证登录，请检查网络后重试。" }
            })
        } catch { verifyingAccount = false; accountState = "offline"; accountMessage = "账号验证组件无法启动，请重试。" }
    }

    func disconnectAccount() {
        guard !isRunning, !importing, !signingOut else { return }
        signingOut = true; cookieReady = false; accountGeneration = UUID()
        setupRunner?.cancel(); setupRunner = nil; accountRunner?.cancel(); accountRunner = nil
        verifyingAccount = false; invalidateSearch()
        session.disconnect { [weak self] result in
            guard let self else { return }
            self.signingOut = false; self.cookieReady = false; self.accountState = "missing"
            self.accountRegion = ""
            switch result {
            case .success:
                self.accountMessage = "已清除本机登录会话。"
                self.notice = "已退出登录，下载记录和音乐文件仍保留。"
            case .failure(let error):
                self.accountMessage = error.localizedDescription
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func search(loadMore: Bool = false) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard engineReady, !signingOut, !query.isEmpty, query.count <= 200 else { return }
        if loadMore && (searching || !searchHasMore || query != submittedQuery || searchKind != submittedKind) { return }
        searchRunner?.cancel()
        queryGeneration = UUID(); let generation = queryGeneration
        let account = accountGeneration
        let offset = loadMore ? nextOffset : 0
        if !loadMore { results = []; selectedResults = []; submittedQuery = query; submittedKind = searchKind }
        searching = true; searched = true; searchMessage = ""
        let task = BackendRunner(); searchRunner = task
        var received = false
        do {
            try task.start(["command": "search", "query": query, "kind": searchKind, "limit": 25,
                            "offset": offset, "cookie_path": cookieURL.path,
                            "storefront": accountRegion.isEmpty ? "us" : accountRegion], onEvent: { [weak self] event in
                guard let self, self.queryGeneration == generation, self.accountGeneration == account,
                      event["event"] as? String == "done" else { return }
                received = true
                self.searchMessage = event["message"] as? String ?? ""
                if event["status"] as? String == "completed" {
                    let region = event["storefront"] as? String ?? ""
                    if loadMore && region != self.searchRegion {
                        self.searchHasMore = false
                        self.searchMessage = "曲库地区已变化，请重新搜索以获取一致的结果。"
                        return
                    }
                    let items = (event["results"] as? [[String: Any]] ?? []).compactMap(CatalogItem.init)
                    let previous = Set(self.results.map(\.id))
                    self.results.append(contentsOf: items.filter { !previous.contains($0.id) })
                    self.searchHasMore = event["has_more"] as? Bool ?? false
                    self.nextOffset = event["next_offset"] as? Int ?? offset + 25
                    self.searchRegion = event["storefront"] as? String ?? ""
                    self.searchPublic = event["storefront_source"] as? String != "account"
                    if event["auth_invalid"] as? Bool == true && self.cookieReady {
                        self.cookieReady = false; self.accountState = "expired"
                    }
                } else { self.searchHasMore = false }
            }, onExit: { [weak self] _ in
                guard let self, self.queryGeneration == generation, self.accountGeneration == account else { return }
                self.searching = false; self.searchRunner = nil
                if !received { self.searchMessage = "搜索未完成，请重试。" }
            })
        } catch { searching = false; searchMessage = "搜索组件无法启动，请重试。" }
    }

    func searchCategoryChanged() {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { search() }
        else { invalidateSearch() }
    }
    func toggleResult(_ id: String) {
        if selectedResults.contains(id) { selectedResults.remove(id) } else { selectedResults.insert(id) }
    }
    func addCatalogItems(_ items: [CatalogItem], begin: Bool = false) {
        var active = Set(jobs.filter { ["pending", "running"].contains($0.status) }.map(\.url))
        var requested: Set<String> = []
        var added = 0
        for item in items {
            guard let normalized = Self.parseLinks(item.url).links.first else { continue }
            if !active.insert(normalized).inserted {
                if let existing = jobs.first(where: { $0.url == normalized && $0.status == "pending" }) { requested.insert(existing.id) }
                continue
            }
            let job = DownloadJob(url: normalized, title: item.title + (item.artist.isEmpty ? "" : " · " + item.artist), format: selectedFormat, directory: outputPath)
            jobs.append(job); requested.insert(job.id)
            added += 1
        }
        notice = added == 0 ? "所选内容已在队列中。" : "已将 \(added) 项加入下载队列。"
        selectedResults = []; persist()
        if begin { selection = "queue"; if !requested.isEmpty { startQueue(only: requested) } }
    }
    func addSelectedResults() { addCatalogItems(results.filter { selectedResults.contains($0.id) }) }

    func startQueue(only requested: Set<String>? = nil) {
        guard !isRunning, !signingOut, !session.credentialsRevoked, engineReady, !importing, pendingCount > 0 else { return }
        guard cookieReady else { errorMessage = "请先在 App 内登录 Apple Music，再开始下载。"; return }
        guard accountState != "no_subscription" else { errorMessage = "当前账号未检测到有效订阅，请确认 Apple Music 会员状态。"; return }
        do { try FileManager.default.createDirectory(atPath: outputPath, withIntermediateDirectories: true) }
        catch { errorMessage = "无法使用这个下载文件夹，请重新选择有写入权限的位置。"; return }
        updatePendingOptions()
        stopRequested = false; stopping = false; isRunning = true
        batchIDs = Set(jobs.filter { $0.status == "pending" && (requested == nil || requested!.contains($0.id)) }.map(\.id))
        notice = ""; runNext()
    }

    private func runNext() {
        guard !stopRequested, cookieReady, !signingOut, !session.credentialsRevoked, let index = jobs.firstIndex(where: { $0.status == "pending" && batchIDs.contains($0.id) }) else {
            isRunning = false; stopping = false; currentID = nil; runner = nil
            notice = stopRequested ? "下载已停止，等待中的任务仍保留。" : "本批任务已处理完毕，可在列表查看结果。"
            persist(); return
        }
        jobs[index].status = "running"; jobs[index].message = "正在连接 Apple Music…"
        jobs[index].completed = 0; jobs[index].total = 0
        let job = jobs[index]; currentID = job.id; finalReceived = false
        let task = BackendRunner(); runner = task; persist()
        do {
            let attemptID = job.id + "-" + String(UUID().uuidString.prefix(8))
            try task.start(["command": "download", "url": job.url, "format": job.format,
                            "output": job.directory, "cookie_path": cookieURL.path, "job_id": attemptID], onEvent: { [weak self] event in
                guard let self, let idx = self.jobs.firstIndex(where: { $0.id == job.id }) else { return }
                if let message = event["message"] as? String { self.jobs[idx].message = message }
                if let completed = event["completed"] as? Int { self.jobs[idx].completed = completed }
                if let total = event["total"] as? Int { self.jobs[idx].total = total }
                if event["event"] as? String == "done" {
                    self.finalReceived = true
                    self.jobs[idx].status = event["status"] as? String ?? "failed"
                    let newFiles = event["files"] as? [String] ?? []
                    self.jobs[idx].files = newFiles + self.jobs[idx].files.filter { !newFiles.contains($0) }
                    if let output = event["output"] as? String, !output.isEmpty { self.jobs[idx].output = output }
                    self.persist()
                }
            }, onExit: { [weak self] code in
                guard let self else { return }
                if let idx = self.jobs.firstIndex(where: { $0.id == job.id }), !self.finalReceived {
                    if self.stopRequested {
                        self.jobs[idx].status = "cancelled"; self.jobs[idx].message = "已停止，可点击重试"
                    } else {
                        self.jobs[idx].status = "failed"; self.jobs[idx].message = "下载组件意外退出（\(code)），可重试此任务。"
                    }
                }
                self.runner = nil; self.persist(); self.runNext()
            })
        } catch {
            jobs[index].status = "failed"; jobs[index].message = "无法启动下载组件。"
            runNext()
        }
    }

    func stop() { stopRequested = true; stopping = true; runner?.cancel() }
    func shutdown() { stopRequested = true; runner?.cancel(); setupRunner?.cancel(); accountRunner?.cancel(); searchRunner?.cancel(); persist() }
    func retry(_ id: String) {
        guard id != currentID, let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].status != "running" else { return }
        jobs[i].status = "pending"; jobs[i].message = "等待重试"; jobs[i].completed = 0; jobs[i].total = 0
        jobs[i].format = selectedFormat; jobs[i].directory = outputPath; persist()
    }
    func retryFailed() { for id in jobs.filter({ ["failed", "partial", "cancelled"].contains($0.status) }).map(\.id) { retry(id) } }
    func remove(_ id: String) {
        guard id != currentID, !jobs.contains(where: { $0.id == id && $0.status == "running" }) else { return }
        jobs.removeAll { $0.id == id }; batchIDs.remove(id); persist()
    }
    func clearCompleted() { jobs.removeAll { $0.status == "completed" && $0.id != currentID }; persist() }
    func openDownloads() { NSWorkspace.shared.open(URL(fileURLWithPath: outputPath)) }
    func reveal(_ job: DownloadJob) {
        if let file = job.files.first, FileManager.default.fileExists(atPath: file) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)])
        } else {
            let path = job.output.isEmpty ? job.directory : job.output
            if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            else { errorMessage = "这个任务的输出文件夹已不存在，可能已被移动或删除。" }
        }
    }
    private func updatePendingOptions() {
        for i in jobs.indices where jobs[i].status == "pending" && !batchIDs.contains(jobs[i].id) {
            jobs[i].format = selectedFormat; jobs[i].directory = outputPath
        }
        if !isRunning {
            for i in jobs.indices where jobs[i].status == "pending" { jobs[i].format = selectedFormat; jobs[i].directory = outputPath }
        }
        persist()
    }
    private func persist() {
        do {
            try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(SavedState(jobs: jobs))
            try data.write(to: supportURL.appendingPathComponent("queue.json"), options: .atomic)
        } catch { notice = "任务记录暂时无法保存；下载文件仍会保存在所选位置。" }
    }
}
