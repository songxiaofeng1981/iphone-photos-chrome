# iPhone Photos for Chrome

**English** | [中文](README.zh-CN.md)

Plug your iPhone into your Mac with a cable, browse its photos in a Chrome tab, pick a few, and save the originals to your Downloads folder.

No iCloud. No syncing your whole library. No Photos app. Nothing running in the background.

![Photo wall](docs/images/wall.png)
<sub>Screenshot from the built-in mock device. The colored blocks stand in for real photos.</sub>

> **Status:** v0.1. It works, but it is early. macOS and Google Chrome only. The interface is in Chinese for now.

---

## Why this exists

Most of the time I don't want to *import* my photos. I want five of them, right now, usually to put somewhere in the browser: a blog post, a CMS, a web chat.

The existing options are all heavier than that job:

- **Photos app** imports into a library you then have to manage.
- **Image Capture** works, but it is a separate app and you have to go find the photos you want.
- **iCloud Photos** means syncing everything through the cloud to get a handful of files.

So this project does one thing: **plug in → see today's photos → pick → export**. The browser is where those photos are going anyway, so that is where you pick them.

## What it does

- Opens straight to your **newest photos**, today by default. Older photos load as you scroll, instead of reading the whole library up front.
- Lets you **select** by click, Shift-click for a range, or a whole day at once. Double-click to see a large preview.
- **Exports originals**: HEIC stays HEIC, and a Live Photo comes with its MOV. Files go to `Downloads/iPhone YYYY-MM-DD/`, keeping their original capture time.

## What it deliberately does not do

- **Never deletes or changes anything on your phone.** There is no code path that writes to the iPhone.
- Does not sync or import your library.
- Does not use iCloud or the network. Your photos only travel over the cable to your own Mac.
- Does not run in the background. The helper starts when you open the photo page and quits when you close it.

---

## Install (no coding needed)

You need: a Mac, Google Chrome, an iPhone, and a cable. Allow about 5 minutes the first time.

### Step 1: Install Python (once)

The installer needs Python 3.10 or newer. The Python that comes with macOS is too old.

1. Go to [python.org/downloads/macos](https://www.python.org/downloads/macos/) and download the latest **macOS 64-bit universal2 installer**.
2. Double-click it and click through the installer.

Already have Python 3.10+? Skip this step. To check, open Terminal and type `python3 --version`.

### Step 2: Download this project

Go to the [Releases](https://github.com/songxiaofeng1981/iphone-photos-chrome/releases/latest) page, download `iphone-photos-chrome-v0.1.0.zip`, and double-click it to unzip.

### Step 3: Run the installer

1. Open **Terminal** (press `⌘ Space`, type *Terminal*, press Return).
2. Type `cd ` (with a space after it), drag the unzipped folder into the Terminal window, and press Return.
3. Type `bash install.sh` and press Return.

It takes a minute or two the first time. When it finishes it prints "安装完成" (installation complete) and the next steps.

> If macOS asks whether Terminal may access your Downloads folder, click **Allow**.

### Step 4: Add the extension to Chrome

1. In Chrome, open `chrome://extensions`.
2. Turn on **Developer mode** (top right).
3. Click **Load unpacked** and choose the `extension` folder inside the project folder.
4. Click the puzzle-piece icon in the toolbar and pin **iPhone 照片**.

Developer mode is needed because the extension is not in the Chrome Web Store yet. Chrome may occasionally remind you that a developer-mode extension is installed. That is expected.

### Step 5: Plug in your iPhone

1. Connect the iPhone with a cable and unlock it.
2. Click the extension icon.
3. The first time, your iPhone asks **"Trust This Computer?"**. Tap **Trust** and enter your passcode.

Your newest photos appear.

---

## Everyday use

| You want to | Do this |
|---|---|
| See today's photos | Click the extension icon. "今天" (Today) is the default view. |
| See older photos | Click "全部" (All), then scroll. More photos load as you go. |
| Select | Click a photo. Shift-click to select a range. "全选这一组" selects a whole day. |
| Look closer | Double-click, or hover and click "放大". Use ← → to move, Space to select, Esc to close. |
| Export | Click "导出" at the bottom right. Files go to `Downloads/iPhone YYYY-MM-DD/`. |

Exporting the same photos twice does not create duplicates. Files that are already there are skipped.

## Privacy and safety

- **Read-only.** The helper only lists and reads files in the iPhone's camera roll (`/DCIM`). It never writes, moves, or deletes anything on the phone.
- **Local only.** Nothing is uploaded anywhere. The helper makes no network requests.
- **What is stored on your Mac:**
  - Thumbnails and previews are cached in `~/Library/Caches/iPhonePhotosHelper`.
  - A log is kept at `~/Library/Logs/iPhonePhotosHelper.log`.
  - `uninstall.sh` removes both.

## Troubleshooting

| What you see | What to do |
|---|---|
| "还差一步：安装读取助手" (helper not installed) | Run `bash install.sh` (Step 3). If you already did, check that the extension ID in `chrome://extensions` is `endldjnpicempoibdmlndkiinmmekggn`. |
| Stuck on "在 iPhone 上点信任" (tap Trust) | Unlock the phone and look for the Trust prompt. |
| You tapped "Don't Trust" by mistake | Unplug and plug the cable back in. If the prompt doesn't come back: on the iPhone, go to Settings → General → Transfer or Reset iPhone → Reset → **Reset Location & Privacy**, then reconnect. |
| "读取助手意外退出" (helper crashed) | Open an [issue](https://github.com/songxiaofeng1981/iphone-photos-chrome/issues/new/choose) and attach the log file `~/Library/Logs/iPhonePhotosHelper.log`. |
| The installer says Python 3.10+ not found | Do Step 1, then run `bash install.sh` again. |

To test the connection without Chrome, plug in the phone and run `bash selftest.sh` in the project folder. It prints how long each step takes.

## Known limitations

- **Only macOS and Google Chrome have been tested.** Other Chromium browsers may work but are not set up by the installer.
- **Edits made on the phone are probably not included.** The camera roll stores the original shot, and Photos keeps edits such as crops and filters separately. This has not been fully verified yet.
- **iCloud "Optimize iPhone Storage":** older photos whose full versions live only in iCloud may not appear.
- **Videos** show only their first frame. Videos over 60 MB get no thumbnail. Portrait videos may show a sideways thumbnail.
- **"Newest first" is decided by folder name** (`100APPLE`, `101APPLE`, …). If your newest photos don't show up first, please open an issue.
- The interface is Chinese-only for now.

## Uninstall

1. In the project folder, run `bash uninstall.sh`. It removes the helper, its cache, and its log. Your exported photos are not touched.
2. Remove the extension in `chrome://extensions`.

## How it works

```
Chrome tab (extension page)
   │  Chrome Native Messaging
   ▼
Helper (Python, runs only while the tab is open)
   │  usbmuxd + AFC, via pymobiledevice3
   ▼
iPhone camera roll (/DCIM), read-only
```

The full reasoning is in [docs/DESIGN.md](docs/DESIGN.md): why a browser tab, why AFC instead of Apple's Image Capture framework, how the first screen is kept fast, and what is planned next.

## Questions, bugs, ideas

- **Bug or problem:** [open an issue](https://github.com/songxiaofeng1981/iphone-photos-chrome/issues/new/choose). Please include the output of `bash selftest.sh` and the log file `~/Library/Logs/iPhonePhotosHelper.log`, your macOS version, iPhone model, and iOS version.
- **Idea or question:** issues are welcome too, in English or Chinese.
- **Code:** see [CONTRIBUTING.md](CONTRIBUTING.md). You can develop without an iPhone using the built-in mock device.

## License

[MIT](LICENSE)
