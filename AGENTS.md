# AGENTS.md — 给接手这个项目的 AI（和人）看的

新开会话时先读完这一页，再动代码。`CLAUDE.md` 只是指向这里，所有说明都只写在这一个文件里；改了项目的约定，就更新这里。

## 1. 这是什么

**iPhone 照片**：Chrome 插件 + Mac 本机“读取助手”。用数据线连 iPhone，在 Chrome 标签页里浏览手机照片，挑几张把原文件导出到 `~/Downloads/iPhone 年-月-日/`。只读手机，绝不写入或删除手机上的东西。

- GitHub：`songxiaofeng1981/iphone-photos-chrome`（公开仓库），本地：`~/Projects/iphone-photos-chrome`
- 作者用中文沟通，常用语音输入，话会口语化：先复述理解、给方案，再动手。

## 2. 分支和版本（2026-10-24 的状态）

| 分支 / 标签 | 内容 |
|---|---|
| **`main`**（当前开发分支） | Swift 读取助手（ImageCaptureCore），不需要 Python；插件带新预览层。2026-10-24 由 `swift-helper` 合并而来。 |
| `python-helper-final`（里程碑标签，和 `v0.1.0` 同一个提交） | 最后一个 Python 读取助手版本（`helper/host.py` + pymobiledevice3，走 AFC，需要用户装 Python 3.10+）。要看旧实现：`git checkout python-helper-final`。 |
| `v0.2.0-beta` … `v0.2.2-beta` | 预发布版。**v0.2.2-beta 是最新**，下载包 `iphone-photos-v0.2.2.zip` 同时含插件和读取助手。GitHub 上标为 “Latest” 的仍是 v0.1.0，因为还没发 v0.2 正式版。 |
| `swift-helper` | 已合并进 `main` 的开发分支，保留作记录，不再在上面开发。 |

**新工作都在 `main` 上做**；开工前先 `git pull`，确认自己在 `main`（`git branch --show-current`）。

## 3. 目录

```
extension/        Chrome 插件，纯 HTML/CSS/JS，无构建步骤
  manifest.json   固定 "key" → 固定扩展 ID；"version" 必须和读取助手版本一致
  wall.html/css/js  照片墙、选择、预览层（仿“照片”App）、导出托盘
  background.js   点图标打开/切换到照片页
helper/           Swift 读取助手（Native Messaging host）
  main.swift      请求分发（Service）、导出、自测、入口
  Common.swift    版本号、消息帧、日志、Item 模型、图片工具
  Sources.swift   PhotoSource 协议 + MockSource（本地文件夹假装手机）
  Phone.swift     PhoneSource：ImageCaptureCore 读真 iPhone
  Info.plist / build.sh   App 包信息、编译（build.sh universal = Intel + Apple 芯片）
  host.py / requirements.txt   旧的 Python 版，仅供参考，安装脚本已不用；不要再改它
dev/
  protocol_test.py  像 Chrome 一样逐条测协议（不插手机 / 模拟手机）
  make_mock_phone.py  生成模拟相机胶卷（需要 Pillow、pillow-heif、av；开发机用）
scripts/package.sh  生成下载包 dist/iphone-photos-vX.Y.Z.zip（校验插件和助手版本一致）
install.sh / uninstall.sh / selftest.sh   用户运行的脚本（中英双语输出）
docs/HELPER.zh-CN.md  下载包里的 README.md
docs/DESIGN*.md     设计说明（第 3.3 节有 v0.2 换用 ImageCaptureCore 的说明）
```

## 4. 不能改的标识

改了会让已安装的用户失效：

- 扩展 ID `endldjnpicempoibdmlndkiinmmekggn`（由 `manifest.json` 的 `key` 决定，不要动 `key`）
- Native Messaging 名称 `com.song.iphone_photos`
- 读取助手 Bundle ID / 签名标识 `com.song.iphone_photos.helper`
- 安装位置 `~/Library/Application Support/iPhonePhotosHelper/iPhonePhotosHelper.app`，可执行文件 `Contents/MacOS/iphone-photos-helper`
- 缓存 `~/Library/Caches/iPhonePhotosHelper`，日志 `~/Library/Logs/iPhonePhotosHelper.log`
- 导出目录 `~/Downloads/iPhone YYYY-MM-DD/`

## 5. 插件 ↔ 读取助手协议

Chrome Native Messaging：每条消息 = 4 字节小端长度 + UTF-8 JSON。助手→Chrome 单条 ≤ 1 MB（所以预览图压到约 650 KB 以内）。请求带 `rid`，回复 `{"rid", "ok": true, "result"}` 或 `{"rid", "ok": false, "code", "error"}`。

| cmd | 参数 | result |
|---|---|---|
| `hello` | | `{version}` |
| `status` | | `{state: ready/nodevice/locked/pairing/denied/error, serial, name, model, ios, message}` |
| `list` | `cursor`（null 或上次返回的值）, `limit` | `{items: [{id, name, ext, kind, live, liveName, size, mainSize, fileCount, t(ms)}], cursor}`；cursor 为 null 表示到底 |
| `refresh` | | `{}`，清空索引，页面随后从头 `list` |
| `thumb` | `id` | `{id, thumb(base64 JPEG)/null, cached, taken("YYYY:MM:DD HH:MM:SS"), w, h, noThumb?}` |
| `preview` | `id` | `{id, data(base64 JPEG)/null}` |
| `export` | `ids` | 过程中发事件 `{event:"progress", rid, index, count, file, done, total}`；结果 `{dir, files, skipped, count}` |
| `reveal` | `path` | `{}`，只打开用户目录下已存在的路径 |

错误码：`device_lost`（页面回到“连接 iPhone”）、`unknown_item`、`bad_cmd`、`too_large`、`error`。插件代码在 `extension/wall.js` 的 `host` 对象和 `onHostEvent`。**改协议必须两边同时改，并更新 `dev/protocol_test.py`。**

## 6. 开发、测试、发布

```bash
bash helper/build.sh                         # 编译本机架构 → helper/build/iPhonePhotosHelper.app
python3 dev/make_mock_phone.py /tmp/mockphone   # 需要 Pillow/pillow-heif/av；没有就用任意含 DCIM/ 的文件夹
BIN=helper/build/iPhonePhotosHelper.app/Contents/MacOS/iphone-photos-helper
HOME=$(mktemp -d) python3 dev/protocol_test.py $BIN                       # 不插手机：5 项
HOME=$(mktemp -d) python3 dev/protocol_test.py $BIN --mock /tmp/mockphone # 模拟手机：24 项
$BIN --selftest --mock /tmp/mockphone        # 命令行自测
bash install.sh                              # 装到本机（会覆盖已安装的助手）
```

- 测试一定用临时 `HOME`：助手按 `$HOME` 找“下载”、缓存和日志（`Common.swift` 里的 `home`），否则导出测试会写进作者真的“下载”文件夹。
- Chrome 里用模拟手机：把文件夹路径写进 `~/Library/Application Support/iPhonePhotosHelper/mock_dir`，删掉即回到真机。
- 测安装脚本：解压下载包，`xattr -rw com.apple.quarantine ...` 模拟“从网上下载”，再用临时 HOME 运行 `install.sh`。
- 发布：同时改 `extension/manifest.json` 的 version、`helper/Common.swift` 的 `helperVersion`、`helper/Info.plist`（两个版本字段），写 CHANGELOG，`bash scripts/package.sh`，测试，提交推送，`gh release create vX.Y.Z-beta dist/iphone-photos-vX.Y.Z.zip --target main --prerelease`（正式版去掉 `-beta` 和 `--prerelease`），再用 curl 下载回来 `cmp` 一遍。

## 7. 和作者合作的规矩

- **改插件代码、读取助手或脚本前，先给 diff，作者同意了再改。** 写文档不用。
- **推送到 GitHub、发 release、合并到 `main` 前，必须在对话里得到明确同意。** 仓库是公开的。
- 外观参照 macOS“照片”App 和快速查看：克制、黑白灰、一个强调色；不要加装饰。
- 出错时先看 `~/Library/Logs/iPhonePhotosHelper.log`，说清原因再修；ImageCaptureCore 的接口以本机 SDK 头文件为准（`$(xcrun --show-sdk-path)/System/Library/Frameworks/ImageCaptureCore.framework/Headers`），不要凭记忆写。
- 长任务中途要说进度。

## 8. 踩过的坑和待验证的事

已解决：
- 手机刚插上会短暂报“已锁定”，打开会话失败 `-9943 Please unlock`，随后马上解锁、目录列完。0.2.0 把这个错误一直记着，页面停在“连接出错”；0.2.1 起当作锁定处理、解锁后重试、目录列完即就绪（`Phone.swift`）。
- `NSHomeDirectory()` 不认 `$HOME`，测试会写进真目录；现在用 `$HOME`。
- `ditto -c -k` 默认会把 `._` 附加文件打进 zip；`package.sh` 用了 `--norsrc --noextattr --noqtn`。
- 新预览层曾只改在本地副本，没进仓库，导致 GitHub 上的插件是旧版。改插件要改仓库里的 `extension/`，Chrome 也应从仓库或下载包的固定位置加载，不要从会被挪走的临时文件夹加载。

待真机验证（作者在另一台 Mac 上测，0.2.1 已能连上）：
- **HEIC 会不会被转成 JPEG**：走相机协议时，iPhone“设置 → 照片 → 传输到 Mac 或 PC”为“自动”可能会转格式。要确认导出的是原始 HEIC，文件大小和 `fileSize` 一致。
- **照片数量**：日志里目录只有 84 个文件，要对比手机实际数量（可能是 iCloud“优化储存空间”或 ImageCaptureCore 的限制）。
- **大图库的目录时间**：ImageCaptureCore 要先把整个目录列完（`deviceDidBecomeReady(withCompleteContentCatalog:)`）才返回第一页，照片很多时首屏可能慢。这正是 v0.1 当初选 AFC 的原因（见 DESIGN 3.3）。
- 实况照片配对（同名 HEIC + MOV）、竖拍视频画面方向、锁屏和“未信任”目前都显示“请解锁”。

## 9. 想做但还没做的

- `install.sh` 顺便把插件复制到固定文件夹并把路径放进剪贴板（参考 `~/Projects/image-organizer/install.sh`），省掉手动放文件夹。
- 智能分类侧边栏（设计不变，分类要多）：拍的（相机拍摄=EXIF Make 为 Apple、HEIC、自拍=前置镜头、实况、全景、视频）、存的（无相机信息的存图、3:4 竖图、长图、修图 App 处理过=EXIF Software）、截的（截屏=PNG 且屏幕分辨率、录屏）、杂的（小图/表情包、动图、可能重复，默认隐藏）、时间、大文件、带位置、还没导出过。“小红书”本身识别不出来。`selftest.sh` 会打印前 5 张的机型/镜头/软件/GPS，先用真机数据校准规则再做。
- 真机验证完第 8 节后：更新 README 截图，发 v0.2.0 正式版（GitHub 的 Latest 才会从 v0.1.0 换过来）。

## 10. 相关项目

`~/Projects/image-organizer`（GitHub `songxiaofeng1981/image-organizer`，“图片整理”）：同一套做法的参考实现（Swift 助手、安装脚本、照片 App 风格界面）。全局技能 `song-mac-chrome-extension` 记录了这套做法和经验。
