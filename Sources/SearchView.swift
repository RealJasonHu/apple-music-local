import SwiftUI
import AppKit

func regionLabel(_ code: String) -> String {
    guard !code.isEmpty else { return "地区待确认" }
    return (Locale(identifier: "zh_CN").localizedString(forRegionCode: code.uppercased()) ?? code.uppercased()) + "曲库"
}

struct SearchControls: View {
    @ObservedObject var model: DownloadModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(accent)
                TextField("搜索歌曲、歌手、专辑或歌单", text: $model.searchText)
                    .textFieldStyle(.plain).font(.system(size: 16)).onSubmit { model.search() }
                    .accessibilityLabel("搜索 Apple Music")
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(muted) }.buttonStyle(.plain).help("清除搜索文字")
                }
                Button { model.search() } label: {
                    HStack(spacing: 7) {
                        if model.searching { ProgressView().controlSize(.small).tint(.white) }
                        Text("搜索").font(.system(size: 12, weight: .semibold))
                    }.frame(minWidth: 54)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.engineReady || model.signingOut)
            }
            HStack {
                Picker("搜索类型", selection: $model.searchKind) {
                    Text("歌曲").tag("songs"); Text("专辑").tag("albums"); Text("歌单").tag("playlists")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 245)
                    .onChange(of: model.searchKind) { _, _ in model.searchCategoryChanged() }
                Spacer()
                Label(model.accountState == "connected" ? regionLabel(model.accountRegion) : "可搜索公开曲库", systemImage: "globe")
                    .font(.system(size: 10)).foregroundStyle(muted)
            }
        }.padding(19).card()
    }
}

struct CatalogResultsView: View {
    @ObservedObject var model: DownloadModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("搜索结果").font(.system(size: 13, weight: .semibold))
                if !model.results.isEmpty {
                    Text("\(model.results.count) 项 · \(regionLabel(model.searchRegion))" + (model.searchPublic ? " · 公开目录" : ""))
                        .font(.system(size: 10)).foregroundStyle(muted)
                }
                Spacer()
                if !model.results.isEmpty {
                    Button(model.selectedResults.count == model.results.count ? "取消全选" : "全选结果") {
                        model.selectedResults = model.selectedResults.count == model.results.count ? [] : Set(model.results.map(\.id))
                    }.buttonStyle(.borderless).font(.system(size: 11))
                    Button { model.addSelectedResults() } label: {
                        Label("加入队列\(model.selectedResults.isEmpty ? "" : " (\(model.selectedResults.count))")", systemImage: "plus")
                            .font(.system(size: 11, weight: .medium))
                    }.buttonStyle(.borderedProminent).disabled(model.selectedResults.isEmpty)
                }
            }.padding(.horizontal, 17).padding(.vertical, 14)
            Divider()
            if model.results.isEmpty {
                VStack(spacing: 12) {
                    if model.searching { ProgressView().controlSize(.large) }
                    else { Image(systemName: model.searched ? "magnifyingglass" : "music.note.house").font(.system(size: 34, weight: .light)).foregroundStyle(accent.opacity(0.65)) }
                    Text(model.searching ? "正在搜索 Apple Music…" : model.searched ? "没有找到结果" : "从喜欢的一首歌开始")
                        .font(.system(size: 14, weight: .medium))
                    Text(model.searching ? "正在读取曲库信息" : model.searched ? (model.searchMessage.isEmpty ? "试试其他关键词，或切换搜索类型。" : model.searchMessage) : "输入歌曲名或歌手，即可在这里选择并下载。")
                        .font(.system(size: 11)).foregroundStyle(muted).multilineTextAlignment(.center).padding(.horizontal, 30)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).frame(minHeight: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.results) { item in
                            CatalogRow(item: item, selected: model.selectedResults.contains(item.id),
                                       queued: model.jobs.contains { $0.url == DownloadModel.parseLinks(item.url).links.first && ["pending", "running"].contains($0.status) },
                                       select: { model.toggleResult(item.id) }, add: { model.addCatalogItems([item]) },
                                       download: { model.addCatalogItems([item], begin: true) }, open: { model.openCatalogPage(item) })
                            if item.id != model.results.last?.id { Divider().padding(.leading, 88) }
                        }
                        if model.searchHasMore {
                            Button { model.search(loadMore: true) } label: {
                                HStack { if model.searching { ProgressView().controlSize(.small) }; Text(model.searching ? "正在加载…" : "加载更多") }
                            }.buttonStyle(.bordered).padding(16).disabled(model.searching)
                        }
                    }.padding(.horizontal, 16)
                }.frame(minHeight: 180)
            }
            if !model.results.isEmpty && !model.searchMessage.isEmpty {
                Divider()
                Text(model.searchMessage).font(.system(size: 10)).foregroundStyle(muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }.frame(maxHeight: .infinity).card()
    }
}

private struct CatalogRow: View {
    let item: CatalogItem
    let selected: Bool
    let queued: Bool
    let select: () -> Void
    let add: () -> Void
    let download: () -> Void
    let open: () -> Void
    private var detail: String {
        if item.kind == "songs" {
            let seconds = item.duration / 1000
            return seconds > 0 ? String(format: "%d:%02d", seconds / 60, seconds % 60) : "歌曲"
        }
        return item.tracks > 0 ? "\(item.tracks) 首" : item.kind == "albums" ? "专辑" : "歌单"
    }
    var body: some View {
        HStack(spacing: 13) {
            Button(action: select) { Image(systemName: selected ? "checkmark.square.fill" : "square").font(.system(size: 16)).foregroundStyle(selected ? accent : muted.opacity(0.5)) }
                .buttonStyle(.plain).accessibilityLabel("选择 \(item.title)")
            AsyncImage(url: item.artworkURL) { image in image.resizable().scaledToFill() } placeholder: {
                ZStack { Color(red: 0.93, green: 0.95, blue: 0.99); Image(systemName: "music.note").foregroundStyle(accent.opacity(0.6)) }
            }.frame(width: 47, height: 47).clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if item.explicit { Text("E").font(.system(size: 8, weight: .bold)).padding(2).background(muted.opacity(0.12), in: RoundedRectangle(cornerRadius: 2)).foregroundStyle(muted) }
                }
                Text(item.artist + (item.album.isEmpty || item.kind != "songs" ? "" : " · " + item.album))
                    .font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(detail).font(.system(size: 10)).monospacedDigit().foregroundStyle(muted).frame(minWidth: 36, alignment: .trailing)
            Button(action: open) { Image(systemName: "arrow.up.right.square") }.buttonStyle(.borderless).foregroundStyle(muted).help("在 App 内查看 Apple Music 页面")
            Button(action: add) { Image(systemName: queued ? "checkmark" : "plus") }.buttonStyle(.bordered).help(queued ? "已在下载队列中" : "加入下载队列").disabled(queued)
            Button("下载", action: download).buttonStyle(.borderedProminent).font(.system(size: 11))
        }.padding(.vertical, 12)
    }
}

struct AccountView: View {
    @ObservedObject var model: DownloadModel
    @ObservedObject var session: AppleMusicSession
    @State private var confirmLogout = false
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: model.accountState == "connected" ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                    .font(.system(size: 26)).foregroundStyle(model.accountState == "connected" ? .green : accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.accountLabel + (model.accountState == "connected" ? " · " + regionLabel(model.accountRegion) : "")).font(.system(size: 13, weight: .semibold))
                    Text(model.accountMessage).font(.system(size: 10)).foregroundStyle(muted).lineLimit(2)
                }
                Spacer()
                Button { model.verifyAccount() } label: {
                    HStack { if model.verifyingAccount { ProgressView().controlSize(.small) }; Text("验证订阅") }
                }.disabled(model.verifyingAccount || !model.cookieReady || model.signingOut)
                Menu {
                    Button("导入浏览器 Cookie 文件…") { model.chooseCookies() }.disabled(model.isRunning || model.importing || !model.engineReady)
                    Divider()
                    Button("退出本机账号", role: .destructive) { confirmLogout = true }.disabled(model.isRunning || model.signingOut)
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 17)) }.menuStyle(.borderlessButton).frame(width: 25)
            }.padding(16).card()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "lock.fill").foregroundStyle(.green).font(.system(size: 10))
                    Text("music.apple.com · Apple 官方页面").font(.system(size: 11)).foregroundStyle(muted)
                    if session.loading { ProgressView().controlSize(.mini) }
                    Spacer()
                    Button { session.goHome() } label: { Image(systemName: "house") }.help("返回 Apple Music 首页")
                    Button { session.reload() } label: { Image(systemName: "arrow.clockwise") }.help("刷新页面")
                }.buttonStyle(.borderless).padding(13)
                Divider()
                AppleMusicWebView(session: session).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 13, bottomTrailingRadius: 13))
            }.frame(maxHeight: .infinity).card()
            Text(session.message.isEmpty ? "登录会话自动保存在本机；Apple 要求验证或会话到期时，需要重新登录。" : session.message)
                .font(.system(size: 10)).foregroundStyle(muted).frame(maxWidth: .infinity, alignment: .leading)
        }.onAppear { session.loadIfNeeded() }
            .confirmationDialog("退出本机账号？", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("退出并清除本机登录", role: .destructive) { model.disconnectAccount() }
                Button("取消", role: .cancel) {}
            } message: { Text("本机登录会话会被清除。下载记录和已经保存的音乐文件会保留。") }
    }
}
