# iPhone 照片（Chrome 插件）

[English](README.md) | **中文**

用数据线把 iPhone 接到 Mac，在 Chrome 里浏览手机照片，挑几张，把原图存到“下载”文件夹。

不走 iCloud，不同步整个相册，不打开“照片”App，也没有任何程序在后台常驻。

![照片墙](docs/images/wall.png)
<sub>截图来自内置的模拟设备，彩色方块代替真实照片。</sub>

> **当前状态**：这是 `swift-helper` 分支，对应预发布版 **v0.2.2-beta**：读取助手改用 Swift，不再需要 Python。还在真机测试中。只支持 macOS 12+ 和 Google Chrome，界面目前只有中文。稳定版 v0.1.0 在 `main` 分支。

---

## 为什么做这个

大多数时候，我并不想“导入”照片，只是想马上拿到其中五张，而且通常是要用在浏览器里：写博客、发到内容后台、在网页版聊天里发出去。

现有的办法都比这件事重：

- **“照片”App**：会导入到图库，导完还得管理图库。
- **“图像捕捉”**：能用，但要另开一个程序，自己去翻找要的照片。
- **iCloud 照片**：为了拿几个文件，得把整个相册都同步到云端。

所以这个项目只做一件事：**插线 → 看今天的照片 → 挑 → 导出**。照片最后反正要去浏览器，那就直接在浏览器里挑。

## 它做什么

- **打开就是最新的照片**，默认停在“今天”。旧照片随滚动加载，不会一上来把整个相册读一遍。
- **挑选**：单击选择，Shift 连选，或者整天全选；双击看大图。
- **导出原文件**：HEIC 还是 HEIC，实况照片会连同 MOV 一起导出。文件放进 `下载/iPhone 年-月-日/`，保留原始拍摄时间。

## 它刻意不做什么

- **绝不删除或修改手机上的任何东西**，代码里没有任何写手机的操作。
- 不同步、不导入图库。
- 不用 iCloud，不联网。照片只通过数据线到你自己的 Mac。
- 不在后台常驻。打开照片页时读取助手才启动，关掉页面它就退出。

---

## 安装（不需要会编程）

需要：一台 Mac（macOS 12 或更新）、Google Chrome、一部 iPhone、一根数据线。不需要 Python、Homebrew 或管理员密码，安装时也不联网。

### 第 1 步：下载

打开 [v0.2.2-beta](https://github.com/songxiaofeng1981/iphone-photos-chrome/releases/tag/v0.2.2-beta) 页面，下载 `iphone-photos-v0.2.2.zip`，双击解压。

### 第 2 步：安装读取助手

1. 打开 **“终端”**（按 `⌘ 空格`，输入“终端”，回车）。
2. 输入 `bash `（后面带一个空格），把解压出来的文件夹里的 `install.sh` 拖进终端窗口，回车。

几秒钟就装好，看到“完成！”即可。

### 第 3 步：把插件加到 Chrome

Chrome 直接从文件夹加载插件，**这个文件夹以后不能删、不能挪**。先把解压出来的 `extension` 文件夹放到一个固定的地方，比如“文稿”里。

1. 在 Chrome 地址栏打开 `chrome://extensions`。
2. 打开右上角的 **开发者模式**。
3. 点 **加载已解压的扩展程序**，选择放好的 `extension` 文件夹。
4. 确认插件 ID 是 `endldjnpicempoibdmlndkiinmmekggn`。
5. 点工具栏的拼图图标，把 **iPhone 照片** 固定到工具栏。

需要开发者模式，是因为插件还没上架 Chrome 网上应用店。Chrome 偶尔会提醒你装了开发者模式的扩展，这是正常的。

### 第 4 步：插上 iPhone

1. 用数据线连接 iPhone，并解锁。
2. 点插件图标。
3. 第一次连接时，手机会弹出 **“要信任此电脑吗？”**，点 **信任**，再输入锁屏密码。

最新的照片就会出现。

---

## 日常使用

| 想做什么 | 怎么做 |
|---|---|
| 看今天的照片 | 点插件图标，默认就是“今天” |
| 看更早的照片 | 点“全部”，往下滚，越滚加载越多 |
| 选择 | 单击照片；Shift 单击可以连选；“全选这一组”选中一整天 |
| 看大图 | 双击，或鼠标移上去点“放大”；← → 切换，空格选择，Esc 关闭 |
| 导出 | 点右下角“导出”，文件放在 `下载/iPhone 年-月-日/` |

同一批照片导出两次不会产生重复文件，已存在的会自动跳过。

## 隐私与安全

- **只读**：读取助手只列出和读取手机相机胶卷（`/DCIM`）里的文件，从不写入、移动或删除手机上的任何东西。
- **只在本地**：什么都不上传，读取助手不发任何网络请求。
- **在 Mac 上留下的东西**：
  - 缩略图和预览缓存在 `~/Library/Caches/iPhonePhotosHelper`。
  - 日志在 `~/Library/Logs/iPhonePhotosHelper.log`。
  - `uninstall.sh` 会把这两处一起删掉。

## 遇到问题

| 看到什么 | 怎么办 |
|---|---|
| “还差一步：安装读取助手” | 运行 `bash install.sh`（第 2 步）。如果已经运行过，到 `chrome://extensions` 核对插件 ID 是否为 `endldjnpicempoibdmlndkiinmmekggn`。 |
| 一直停在“请解锁 iPhone” | 解锁手机，看有没有“信任此电脑”弹窗。 |
| 不小心点了“不信任” | 拔线再插。如果不再弹出：iPhone 设置 → 通用 → 传输或还原 iPhone → 还原 → **还原位置与隐私**，然后重新连接。 |
| “读取助手意外退出” | [提一个 issue](https://github.com/songxiaofeng1981/iphone-photos-chrome/issues/new/choose)，附上日志 `~/Library/Logs/iPhonePhotosHelper.log`。 |
| 装过 v0.1（Python 版） | 直接运行新的 `install.sh` 覆盖即可。想删掉旧的 Python 文件：`bash install.sh --remove-python`。 |

不想开 Chrome、只想测连接：插上手机，运行 `bash selftest.sh`，它会打印每一步用了多久，以及几张照片的机型、镜头等信息。

## 已知限制

- **只在 macOS + Google Chrome 上测试过**。其他 Chromium 浏览器可能能用，但安装程序没有为它们做配置。
- **手机上做过的编辑大概率不会带出来**。相机胶卷里存的是原片，裁剪、滤镜等编辑由“照片”App 另外保存。这一点还没有完全验证。
- **开了 iCloud“优化 iPhone 储存空间”**：完整版本只在 iCloud 上的旧照片可能不显示。
- **视频**只显示手机提供的一帧画面。
- **HEIC 是否保持原格式还没验证**：v0.2 走苹果的相机协议，iPhone“设置 → 照片 → 传输到 Mac 或 PC”设为“自动”时，可能会转成 JPEG。如果导出的不是 HEIC，可以改成“保留原片”。
- **照片目录要先全部列完**才显示第一页，照片很多时首屏可能比 v0.1 慢。
- 界面目前只有中文。

## 卸载

1. 在下载包的文件夹里运行 `bash uninstall.sh`。它会删除读取助手、缓存和日志，已经导出的照片不受影响。
2. 到 `chrome://extensions` 移除插件。

## 工作原理

```
Chrome 标签页（插件页面）
   │  Chrome Native Messaging
   ▼
读取助手（Swift 小程序，只在标签页打开时运行）
   │  苹果 ImageCaptureCore（“图像捕捉”用的框架）
   ▼
iPhone 相机胶卷，只读
```

完整的设计思路见 [docs/DESIGN.zh-CN.md](docs/DESIGN.zh-CN.md)：为什么放在浏览器标签页里，v0.1 为什么用 AFC、v0.2 为什么改用 ImageCaptureCore，首屏是怎么做快的，以及后续计划。给 AI 和开发者的项目说明见 [AGENTS.md](AGENTS.md)。

## 提问、报 bug、提想法

- **报 bug**：[提一个 issue](https://github.com/songxiaofeng1981/iphone-photos-chrome/issues/new/choose)。请附上 `bash selftest.sh` 的输出、日志文件 `~/Library/Logs/iPhonePhotosHelper.log`，以及 macOS 版本、iPhone 型号和 iOS 版本。
- **想法或疑问**：也欢迎提 issue，中文英文都可以。
- **贡献代码**：见 [CONTRIBUTING.md](CONTRIBUTING.md)。没有 iPhone 也能开发，项目内置了模拟设备。

## 许可证

[MIT](LICENSE)
