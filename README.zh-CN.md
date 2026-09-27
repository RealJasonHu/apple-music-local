# Apple Music Local

运行在 Mac 上的原生 Apple Music 搜索与下载工具，使用你自己的会员账号。基于 SwiftUI、WebKit、[Gamdl](https://github.com/glomatico/gamdl) 和 FFmpeg。

**[下载 Mac App](https://github.com/RealJasonHu/apple-music-local/releases/latest)** · [English](README.md)

支持 **Apple Silicon，macOS 14 或更新版本**，界面为简体中文。

## 功能

- 在 App 内的 Apple 官方页面登录，保存本机会话，重启后恢复；在线验证订阅状态。
- 按账号地区搜索歌曲、专辑、歌单，支持分页、多选加入队列和直接下载。
- 批量粘贴 Apple Music 分享链接，自动过滤重复链接。
- MP3 320 kbps、WAV、原始 AAC/M4A；可选择下载目录，默认 Downloads。
- 下载进度、停止、重试、记录恢复，以及在 Finder 中查看文件。

当前音源是**有损网页 AAC**。转成 WAV 不会提高原始音质，MP3 会再次有损编码。目前没有原生无损或 FLAC 下载，也不支持视频和 Intel Mac。

## 开始使用

1. 在 [Releases](https://github.com/RealJasonHu/apple-music-local/releases/latest) 下载 ZIP，解压后把 **Apple Music Local.app** 拖到“应用程序”。
2. 点击 **在 App 内登录 / 账号与登录**，在 Apple 官方页面完成登录及验证。下载需要有效会员和对应内容访问权限。
3. 点击 **搜索音乐**，输入歌名或歌手。选择格式与保存位置，直接下载，或多选后加入队列统一开始。
4. 已有分享链接可在 **下载队列** 中批量粘贴，每行一个。

发布版本采用本机 ad-hoc 签名，**没有 Apple 公证**。首次打开可能需要在系统设置中明确允许，参考 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。无需关闭全局安全保护。

会话能在正常退出与重启后保留，但 Apple 的到期、撤销或安全验证仍可能要求重新登录。账号菜单提供 Cookie 文件导入作为兼容方式，使用文件选择器即可，不要把凭据内容粘贴到聊天、Issue 或音乐链接框。

## 数据与验证

会话及记录保存在本机应用数据目录，不包含开发者运营的账号服务器或遥测服务。Apple 及其媒体服务会收到登录、搜索、封面和下载所需请求。每次下载使用独立目录，重试保留旧文件。退出账号保留音乐文件和下载记录。

[测试记录](docs/TESTING.md)区分自动化检查、真实下载测试与尚未实测的全新登录双重认证流程。

## 源码构建

```sh
git clone https://github.com/RealJasonHu/apple-music-local.git
cd apple-music-local
./build.sh
./scripts/test.sh
```

需要 Apple Silicon Mac 和 Xcode Command Line Tools。构建会下载固定版本的运行时与依赖，产物位于 `dist/Apple Music Local.app`，不依赖开发者电脑上的其他目录。[构建说明](docs/BUILDING.md)

原创源码使用 [MIT 许可证](LICENSE)。第三方依赖具有各自的许可条件，包括 copyleft 和非商业条款，安装包并非全部采用 MIT；再分发前请查看[第三方说明](THIRD_PARTY_NOTICES.md)及 Release 附带的源码与许可证材料。

本项目与 Apple Inc. 无关联，不提供账号、凭据、音乐或会员权限。请仅用于你有权访问和复制的内容及用途。
