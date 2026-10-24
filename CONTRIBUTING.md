# Contributing / 参与贡献

Issues and pull requests are welcome, in English or Chinese.
欢迎提 issue 和 PR，中文英文都可以。

## Reporting a problem / 报告问题

Please use the issue templates and include:
请使用 issue 模板，并附上：

- the output of `bash selftest.sh` / `bash selftest.sh` 的输出
- the log / 日志：`~/Library/Logs/iPhonePhotosHelper.log`
- macOS version, iPhone model, iOS version / macOS 版本、iPhone 型号、iOS 版本

The log contains file names from your camera roll (for example `IMG_1234.HEIC`) but no photo content. Remove anything you don't want to share.
日志里有相机胶卷的文件名（比如 `IMG_1234.HEIC`），但不含照片内容。不想公开的内容可以先删掉。

## Development setup / 开发环境

Needs the Xcode Command Line Tools (`xcode-select --install`). Work on the `swift-helper` branch.
需要 Xcode 命令行工具（`xcode-select --install`）。在 `swift-helper` 分支上开发。

```bash
bash install.sh          # builds the Swift helper from source and registers it / 从源码编译 Swift 助手并注册
```

Then load `extension/` in `chrome://extensions` (Developer mode → Load unpacked).
然后在 `chrome://extensions` 里加载 `extension/`（开发者模式 → 加载已解压的扩展程序）。

Where things live after install / 安装后的位置：

| What / 内容 | Path / 路径 |
|---|---|
| Installed helper / 已安装的读取助手 | `~/Library/Application Support/iPhonePhotosHelper/iPhonePhotosHelper.app` |
| Cache / 缓存 | `~/Library/Caches/iPhonePhotosHelper` |
| Log / 日志 | `~/Library/Logs/iPhonePhotosHelper.log` |

**After editing `helper/*.swift`**, run `bash install.sh` again, then close and reopen the photo page.
**After editing anything in `extension/`**, click the reload icon on the extension card in `chrome://extensions`, then reload the photo page.

**改了 `helper/*.swift` 之后**，重新运行 `bash install.sh`，再关掉照片页重新打开。
**改了 `extension/` 里的文件之后**，在 `chrome://extensions` 的插件卡片上点刷新图标，再刷新照片页。

`helper/host.py` is the old Python helper (v0.1), kept for reference only. / `helper/host.py` 是旧的 Python 版（v0.1），只留作参考。

## Tests / 测试

```bash
bash helper/build.sh
BIN=helper/build/iPhonePhotosHelper.app/Contents/MacOS/iphone-photos-helper
HOME=$(mktemp -d) python3 dev/protocol_test.py $BIN                         # no phone / 不插手机
HOME=$(mktemp -d) python3 dev/protocol_test.py $BIN --mock /tmp/mockphone   # mock phone / 模拟手机
```

Use a temporary `HOME` so exports and caches stay out of your real home folder.
用临时 `HOME`，导出和缓存就不会写进你真正的用户目录。

## Working without an iPhone / 没有 iPhone 也能开发

The helper can read a local folder instead of a phone.
读取助手可以读取一个本地文件夹来代替手机。

```bash
python3 dev/make_mock_phone.py /tmp/mockphone   # fake camera roll; needs Pillow, pillow-heif, av / 生成模拟相机胶卷，需要 Pillow、pillow-heif、av

# Command line / 命令行：
helper/build/iPhonePhotosHelper.app/Contents/MacOS/iphone-photos-helper --selftest --mock /tmp/mockphone

# In Chrome / 在 Chrome 里：the helper launched by Chrome reads this file
# Chrome 启动的读取助手会读取这个文件
echo /tmp/mockphone > "$HOME/Library/Application Support/iPhonePhotosHelper/mock_dir"
# Remove it to go back to the real phone / 删掉它就回到真手机
rm "$HOME/Library/Application Support/iPhonePhotosHelper/mock_dir"
```

## Ground rules / 基本原则

1. **Never write to or delete from the phone.** Never call ImageCaptureCore's delete APIs or download options such as `ICDeleteAfterSuccessfulDownload`. Clean-up features produce suggestions only.
   **永远不写入、不删除手机上的东西。** 不要调用 ImageCaptureCore 的删除接口，也不要用 `ICDeleteAfterSuccessfulDownload` 这类下载选项。整理类功能只给建议。
2. **Nothing goes to stdout in the helper** except protocol messages. Don't `print` outside `--selftest`; log with `log()` from `Common.swift`.
   **读取助手的 stdout 只能输出协议消息。** 除了 `--selftest`，不要用 `print`；输出信息请用 `Common.swift` 里的 `log()`。
3. **Keep the first screen fast.** If a change reads more from the phone before the first thumbnails appear, explain why in the PR, with `selftest.sh` numbers before and after.
   **保持首屏快。** 如果改动让首屏出图前多读了手机上的数据，请在 PR 里说明原因，并附上改动前后的 `selftest.sh` 数据。
4. **No network calls** from the helper or the extension without discussing it in an issue first.
   **不经 issue 讨论，读取助手和插件都不要加任何网络请求。**
5. Read [docs/DESIGN.md](docs/DESIGN.md) before larger changes. If your change conflicts with a decision there, say which one and why.
   较大的改动前请先读 [docs/DESIGN.zh-CN.md](docs/DESIGN.zh-CN.md)。如果改动和其中的某个决定冲突，请说明是哪一条、为什么。

## Pull requests / 提交 PR

- One topic per PR. / 一个 PR 只做一件事。
- Describe how you tested: mock device, real iPhone (model and iOS version), or both.
  写清楚怎么测的：模拟设备、真 iPhone（型号和 iOS 版本），或两者都有。
- Update both language versions of any doc you change.
  改了文档的话，中英两个版本都要更新。
