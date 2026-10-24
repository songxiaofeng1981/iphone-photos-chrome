# Changelog / 更新记录

## v0.2.0 — unreleased / 未发布（branch `swift-helper`）

- New helper in Swift on Apple's ImageCaptureCore: nothing to install on the Mac (no Python, Homebrew or admin password),
  and installing needs no network. Same Native Messaging protocol, so the extension is unchanged.
  读取助手改用 Swift + 苹果自带的 ImageCaptureCore：Mac 上什么都不用另装（不需要 Python、Homebrew、管理员密码），安装时不联网。
  协议不变，插件不用改。
- Thumbnails and video frames come from the phone itself; no HEIC or video decoding libraries.
  缩略图和视频画面由手机直接提供，不再需要 HEIC 和视频解码库。
- `selftest.sh` also prints counts by format and the camera, lens, software and GPS of the newest photos.
  `selftest.sh` 额外打印按格式的数量，以及最新几张照片的机型、镜头、软件和 GPS。
- `dev/protocol_test.py` checks every command against a mock phone; `scripts/package.sh` builds the download zip.
  `dev/protocol_test.py` 用模拟手机检查每条命令；`scripts/package.sh` 生成下载包。
- `install.sh --remove-python` deletes the old 0.1 Python helper. Not yet tested on a real iPhone.
  `install.sh --remove-python` 删除 0.1 版的 Python 助手。尚未在真 iPhone 上测试。

## v0.1.0 — 2026-10-23

First public version. / 第一个公开版本。

- Browse iPhone photos over USB in a Chrome tab, newest first, with paged loading.
  在 Chrome 标签页里通过数据线浏览 iPhone 照片，最新优先，分页加载。
- Fast thumbnails from embedded HEIC thumbnails; viewport-driven loading; disk cache.
  用 HEIC 内嵌缩略图快速出图；只加载屏幕附近的缩略图；磁盘缓存。
- Select (click, Shift-click, whole day), large preview, export originals (Live Photos include MOV).
  选择（单击、Shift 连选、整天全选）、大图预览、导出原文件（实况照片含 MOV）。
- Read-only by design: nothing is ever written to or deleted from the phone.
  从设计上保证只读：不写入、不删除手机上的任何东西。
- `install.sh`, `selftest.sh`, `uninstall.sh`; mock device for development.
  安装、自测、卸载脚本；开发用的模拟设备。
