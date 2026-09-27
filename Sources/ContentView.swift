import AppKit
import SwiftUI

let ink = Color(red: 0.13, green: 0.17, blue: 0.23)
let muted = Color(red: 0.43, green: 0.48, blue: 0.55)
let accent = Color(red: 0.16, green: 0.35, blue: 0.84)
let borderColor = Color(red: 0.88, green: 0.90, blue: 0.94)

struct ContentView: View {
    @ObservedObject var model: DownloadModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 19) {
                header
                if model.selection == "search" {
                    SearchControls(model: model)
                    optionsCard
                    CatalogResultsView(model: model)
                } else if model.selection == "account" {
                    AccountView(model: model, session: model.session)
                } else {
                    if model.selection == "queue" {
                        linkCard
                        optionsCard
                    }
                    queueCard
                }
                footer
            }
            .padding(.horizontal, 30).padding(.top, 34).padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.967, green: 0.974, blue: 0.984))
        }
        .foregroundStyle(ink)
        .tint(accent)
        .sheet(isPresented: $model.showHelp) { HelpView(model: model) }
        .alert("请检查", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13).fill(LinearGradient(colors: [accent, Color(red: 0.30, green: 0.62, blue: 0.91)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "waveform").font(.system(size: 23, weight: .medium)).foregroundStyle(.white)
                }.frame(width: 43, height: 43)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Music Local").font(.system(size: 17, weight: .bold))
                    Text("你的本地音乐库").font(.system(size: 11)).foregroundStyle(muted)
                }
            }.padding(.bottom, 35)
            Text("音乐空间").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(muted).padding(.leading, 12).padding(.bottom, 10)
            navigationRow("搜索音乐", symbol: "magnifyingglass", id: "search", count: 0)
            navigationRow("下载队列", symbol: "arrow.down.circle", id: "queue", count: model.jobs.count)
            navigationRow("下载记录", symbol: "checkmark.circle", id: "completed", count: model.completedCount)
            Button { model.showHelp = true } label: {
                Label("使用帮助", systemImage: "questionmark.circle").font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.buttonStyle(.plain).foregroundStyle(muted).padding(.top, 5)
            Spacer()
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 7) {
                    Circle().fill(model.accountState == "connected" ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(model.accountLabel).font(.system(size: 11, weight: .semibold))
                }
                Text(model.accountState == "connected" ? "订阅有效 · " + regionLabel(model.accountRegion) : model.accountMessage)
                    .font(.system(size: 11)).foregroundStyle(muted).lineSpacing(4).lineLimit(3)
                Button { model.openAccount() } label: {
                    Label(model.cookieReady ? "账号与登录" : "在 App 内登录", systemImage: "person.crop.circle")
                        .font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.borderedProminent).disabled(model.signingOut)
                Text("登录会话自动保存在本机").font(.system(size: 9)).foregroundStyle(muted)
            }.padding(13).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(borderColor.opacity(0.7)))
            Text("MAC APP · 2.0").font(.system(size: 9, weight: .medium)).tracking(1.2).foregroundStyle(muted.opacity(0.75)).padding(.top, 18).padding(.leading, 4)
        }
        .padding(.horizontal, 18).padding(.top, 52).padding(.bottom, 24)
        .frame(width: 215)
        .background(Color(red: 0.935, green: 0.950, blue: 0.972))
    }

    private func navigationRow(_ title: String, symbol: String, id: String, count: Int) -> some View {
        Button { model.selection = id } label: {
            HStack {
                Image(systemName: symbol).font(.system(size: 16)).frame(width: 20)
                Text(title).font(.system(size: 13, weight: model.selection == id ? .semibold : .regular))
                Spacer()
                if count > 0 { Text("\(count)").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(model.selection == id ? accent.opacity(0.12) : .black.opacity(0.04), in: Capsule()) }
            }.padding(12).foregroundStyle(model.selection == id ? accent : muted)
                .background(model.selection == id ? .white : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).padding(.bottom, 4)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Text("APPLE MUSIC LOCAL").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(accent)
                Text(model.selection == "search" ? "搜索 Apple Music" : model.selection == "account" ? "账号与登录" : model.selection == "completed" ? "下载记录" : "音乐下载").font(.system(size: 29, weight: .bold))
                Text(model.selection == "search" ? "直接检索歌曲、专辑和歌单，选择后即可下载。" : model.selection == "account" ? "在 Apple 官方页面登录，App 自动保存并使用授权会话。" : model.selection == "completed" ? "已完成的音乐与部分完成的任务，随时在 Finder 中查看。" : "批量添加歌曲、专辑或歌单，保存到你选择的文件夹。")
                    .font(.system(size: 12)).foregroundStyle(muted)
            }
            Spacer()
            Button { model.openDownloads() } label: { Label("打开文件夹", systemImage: "folder").font(.system(size: 12)) }
                .buttonStyle(.bordered).controlSize(.large)
        }
    }

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("添加音乐", systemImage: "link").font(.system(size: 13, weight: .semibold))
                Text("每行一个链接").font(.system(size: 11)).foregroundStyle(muted)
                Spacer()
                Button { model.pasteLinks() } label: { Label("粘贴链接", systemImage: "doc.on.clipboard").font(.system(size: 11)) }.buttonStyle(.borderless)
            }
            ZStack(alignment: .topLeading) {
                if model.linkText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("把 Apple Music 分享链接粘贴到这里…")
                        Text("支持多个链接，自动去重").foregroundStyle(muted.opacity(0.65))
                    }.font(.system(size: 12)).foregroundStyle(muted).padding(.horizontal, 11).padding(.top, 11).allowsHitTesting(false)
                }
                TextEditor(text: $model.linkText).font(.system(size: 12)).scrollContentBackground(.hidden)
                    .padding(6).frame(height: 98).onChange(of: model.linkText) { _, _ in model.guardCookiePaste() }
                    .accessibilityLabel("批量音乐链接")
            }.background(Color(red: 0.982, green: 0.986, blue: 0.994), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(borderColor))
            HStack {
                let parsed = DownloadModel.parseLinks(model.linkText)
                Text(model.linkText.isEmpty ? "从 Apple Music 的“分享”菜单复制链接" : "识别到 \(parsed.links.count) 个有效链接")
                    .font(.system(size: 11)).foregroundStyle(muted)
                Spacer()
                Button { model.enqueue() } label: { Label("添加到队列", systemImage: "plus").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 5) }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(parsed.links.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }.padding(17).card()
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("保存格式").font(.system(size: 11, weight: .semibold)).foregroundStyle(muted)
                    Picker("保存格式", selection: $model.selectedFormat) {
                        Text("MP3").tag("mp3"); Text("WAV").tag("wav"); Text("AAC").tag("aac")
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 215).disabled(model.isRunning)
                }
                Rectangle().fill(borderColor).frame(width: 1, height: 39)
                VStack(alignment: .leading, spacing: 8) {
                    Text("下载位置").font(.system(size: 11, weight: .semibold)).foregroundStyle(muted)
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").foregroundStyle(Color(red: 0.50, green: 0.64, blue: 0.83))
                        Text(model.outputPath).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).help(model.outputPath)
                        Spacer(minLength: 5)
                        Button("选择…") { model.chooseFolder() }.font(.system(size: 11)).disabled(model.isRunning)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(model.formatNote).font(.system(size: 10)).foregroundStyle(muted)
        }.padding(17).card()
    }

    private var queueCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(model.selection == "completed" ? "下载结果" : "下载队列").font(.system(size: 13, weight: .semibold))
                Text("\(model.visibleJobs.count) 个链接").font(.system(size: 10)).foregroundStyle(muted)
                Spacer()
                if model.attentionCount > 0 && !model.isRunning {
                    Button("重试未完成") { model.retryFailed(); model.selection = "queue" }.font(.system(size: 11)).buttonStyle(.borderless)
                }
                if model.completedCount > 0 {
                    Button("清除完成记录") { model.clearCompleted() }.font(.system(size: 11)).buttonStyle(.borderless).disabled(model.isRunning)
                }
                if model.isRunning {
                    Button { model.stop() } label: { Label(model.stopping ? "正在停止…" : "停止", systemImage: "stop.fill").font(.system(size: 11)) }
                        .buttonStyle(.bordered).disabled(model.stopping)
                } else if model.selection == "queue" {
                    Button { model.startQueue() } label: { Label("开始下载\(model.pendingCount > 0 ? " (\(model.pendingCount))" : "")", systemImage: "arrow.down").font(.system(size: 12, weight: .semibold)) }
                        .buttonStyle(.borderedProminent).disabled(model.pendingCount == 0 || !model.engineReady || model.importing || model.signingOut)
                }
            }.padding(.horizontal, 17).padding(.vertical, 14)
            Divider()
            if model.visibleJobs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: model.selection == "completed" ? "checkmark.seal" : "music.note.list").font(.system(size: 30, weight: .light)).foregroundStyle(accent.opacity(0.65))
                    Text(model.selection == "completed" ? "还没有下载记录" : "准备好你的下一份歌单").font(.system(size: 13, weight: .medium))
                    Text(model.selection == "completed" ? "完成的任务会出现在这里。" : "添加链接后，点击“开始下载”。").font(.system(size: 11)).foregroundStyle(muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).frame(minHeight: 145)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleJobs) { job in
                            JobRow(job: job, retry: { model.retry(job.id) }, remove: { model.remove(job.id) }, reveal: { model.reveal(job) })
                            if job.id != model.visibleJobs.last?.id { Divider().padding(.leading, 59) }
                        }
                    }.padding(.horizontal, 15)
                }.frame(minHeight: 145)
            }
            if model.isRunning {
                Divider()
                HStack(spacing: 12) {
                    ProgressView(value: Double(model.batchCompleted), total: Double(max(model.batchTotal, 1))).frame(maxWidth: .infinity)
                    Text("已处理 \(model.batchCompleted) / \(model.batchTotal) 个链接").font(.system(size: 10)).foregroundStyle(muted)
                }.padding(14)
            }
        }.frame(maxHeight: .infinity).card()
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: model.engineReady ? "checkmark.circle.fill" : "clock").foregroundStyle(model.engineReady ? Color.green.opacity(0.8) : muted)
            Text(model.notice.isEmpty ? model.engineMessage : model.notice).lineLimit(2)
            Spacer(minLength: 12)
            Label("凭据保存在本机", systemImage: "lock").foregroundStyle(muted)
        }.font(.system(size: 10)).foregroundStyle(muted)
    }
}

private struct JobRow: View {
    let job: DownloadJob
    var retry: () -> Void
    var remove: () -> Void
    var reveal: () -> Void
    private var color: Color {
        switch job.status { case "completed": return .green; case "running": return accent; case "failed": return .red; case "partial": return .orange; default: return muted }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(color.opacity(0.08))
                Image(systemName: job.status == "completed" ? "checkmark" : job.status == "running" ? "arrow.down" : "music.note").font(.system(size: 15, weight: .medium)).foregroundStyle(color)
            }.frame(width: 34, height: 38)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(job.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(job.format.uppercased()).font(.system(size: 8, weight: .semibold)).foregroundStyle(muted).padding(.horizontal, 5).padding(.vertical, 2).background(.black.opacity(0.035), in: Capsule())
                }
                Text(job.url).font(.system(size: 10)).foregroundStyle(muted.opacity(0.8)).lineLimit(1).truncationMode(.middle)
                if job.status != "pending" { Text(job.message).font(.system(size: 10)).foregroundStyle(job.status == "failed" ? Color.red : muted).lineLimit(2).textSelection(.enabled) }
                if job.status == "running" {
                    if job.total > 0 { ProgressView(value: Double(min(job.completed, job.total)), total: Double(job.total)).padding(.top, 3) }
                    else { HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("正在处理…").font(.system(size: 9)).foregroundStyle(muted) } }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 9) {
                Text(job.statusName).font(.system(size: 10, weight: .medium)).foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 4).background(color.opacity(0.07), in: Capsule())
                HStack(spacing: 10) {
                    if !job.files.isEmpty || ["completed", "partial"].contains(job.status) { Button(action: reveal) { Image(systemName: "folder") }.help("在 Finder 中查看") }
                    if ["failed", "partial", "cancelled"].contains(job.status) { Button(action: retry) { Image(systemName: "arrow.clockwise") }.help("重试此任务") }
                    if job.status != "running" { Button(action: remove) { Image(systemName: "xmark") }.help("移除记录，保留文件") }
                }.font(.system(size: 10)).buttonStyle(.borderless).foregroundStyle(muted)
            }
        }.padding(.vertical, 14)
    }
}

private struct HelpView: View {
    @ObservedObject var model: DownloadModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("开始使用 Music Local").font(.system(size: 24, weight: .bold))
                    Text("登录、搜索、下载，都在这个 App 中完成。 ").font(.system(size: 12)).foregroundStyle(muted)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            helpStep("1", title: "在 App 内登录 Apple Music", detail: "左侧点击“在 App 内登录”，在 Apple 官方页面输入账号并完成验证。会话会保存在本机，退出 App 后仍可恢复；授权到期时需要重新登录。")
            Button("打开账号与登录") { dismiss(); model.openAccount() }.padding(.leading, 38)
            helpStep("2", title: "搜索你想下载的音乐", detail: "进入“搜索音乐”，输入歌曲名、歌手或关键词。可切换歌曲、专辑、歌单，按账号地区检索，支持多选后批量加入队列。")
            helpStep("3", title: "选择格式和位置，开始下载", detail: "选择 MP3、WAV 或 AAC 及保存文件夹。可从搜索结果直接下载，或进入下载队列统一开始。原有的批量链接粘贴仍然可用。")
            DisclosureGroup("兼容方式：从浏览器导入 Cookie 文件") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("如 Apple 暂时不允许在内置页面登录，可在浏览器登录后导出该站点 Netscape cookies.txt，再通过文件选择器导入。无需粘贴 Cookie 内容。")
                        .font(.system(size: 11)).foregroundStyle(muted)
                    Button("导入 Cookie 文件…") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.chooseCookies() } }
                        .disabled(model.isRunning || model.importing || !model.engineReady)
                }.padding(.top, 8)
            }.font(.system(size: 11)).foregroundStyle(muted)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("关于音质与下载结果").font(.system(size: 12, weight: .semibold))
                Text("当前获取 Apple Music 网页 AAC 音源。MP3 为再次有损编码；WAV 不会提升原始音质。原始 M4A 会保留在所选目录的 Originals 文件夹。任务按真实逐曲结果显示完成、部分完成或失败。")
                    .font(.system(size: 11)).foregroundStyle(muted).lineSpacing(4)
                Text("登录会话只保存在本机；Apple 要求时重新验证。此 App 基于 Gamdl 3.9.1 与 FFmpeg，未提供原生无损下载。")
                    .font(.system(size: 10)).foregroundStyle(muted).lineSpacing(4)
            }
        }.padding(32).frame(width: 660).foregroundStyle(ink).background(Color.white)
    }
    private func helpStep(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text(number).font(.system(size: 12, weight: .bold)).foregroundStyle(accent).frame(width: 25, height: 25).background(accent.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension View {
    func card() -> some View {
        background(Color.white, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(borderColor.opacity(0.8)))
            .shadow(color: .black.opacity(0.015), radius: 4, y: 2)
    }
}
