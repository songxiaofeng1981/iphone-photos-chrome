# iPhone Photos for Chrome

**English** | [中文](README.zh-CN.md)

Plug your iPhone into your Mac with a cable, browse its photos in a Chrome tab, pick a few, and save the originals to your Downloads folder.

No iCloud. No syncing your whole library. No Photos app. Nothing running in the background.

![Photo wall](docs/images/wall.png)
<sub>Screenshot from the built-in mock device. The colored blocks stand in for real photos.</sub>

> **Status:** this is the `swift-helper` branch, released as the pre-release **v0.2.2-beta**: the helper is now written in Swift and no longer needs Python. Still being tested on real iPhones. macOS 12+ and Google Chrome only. The interface is in Chinese for now. The stable v0.1.0 is on `main`.

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

You need: a Mac (macOS 12 or later), Google Chrome, an iPhone, and a cable. No Python, Homebrew or admin password, and the installer does not use the network.

### Step 1: Download

Open the [v0.2.2-beta](https://github.com/songxiaofeng1981/iphone-photos-chrome/releases/tag/v0.2.2-beta) page, download `iphone-photos-v0.2.2.zip`, and double-click it to unzip.

### Step 2: Install the helper

1. Open **Terminal** (press `⌘ Space`, type *Terminal*, press Return).
2. Type `bash ` (with a space after it), drag `install.sh` from the unzipped folder into the Terminal window, and press Return.

It takes a few seconds and prints "Done!".

### Step 3: Add the extension to Chrome

Chrome loads the extension straight from a folder, and **that folder must stay where it is**. First move the unzipped `extension` folder somewhere permanent, for example into Documents.

1. In Chrome, open `chrome://extensions`.
2. Turn on **Developer mode** (top right).
3. Click **Load unpacked** and choose that `extension` folder.
4. Check that the extension ID is `endldjnpicempoibdmlndkiinmmekggn`.
5. Click the puzzle-piece icon in the toolbar and pin **iPhone 照片**.

Developer mode is needed because the extension is not in the Chrome Web Store yet. Chrome may occasionally remind you that a developer-mode extension is installed. That is expected.

### Step 4: Plug in your iPhone

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
| "还差一步：安装读取助手" (helper not installed) | Run `bash install.sh` (Step 2). If you already did, check that the extension ID in `chrome://extensions` is `endldjnpicempoibdmlndkiinmmekggn`. |
| Stuck on "请解锁 iPhone" (unlock your iPhone) | Unlock the phone and look for the "Trust This Computer?" prompt. |
| You tapped "Don't Trust" by mistake | Unplug and plug the cable back in. If the prompt doesn't come back: on the iPhone, go to Settings → General → Transfer or Reset iPhone → Reset → **Reset Location & Privacy**, then reconnect. |
| "读取助手意外退出" (helper crashed) | Open an [issue](https://github.com/songxiaofeng1981/iphone-photos-chrome/issues/new/choose) and attach the log file `~/Library/Logs/iPhonePhotosHelper.log`. |
| You had v0.1 (the Python helper) | Just run the new `install.sh` over it. To delete the old Python files: `bash install.sh --remove-python`. |

To test the connection without Chrome, plug in the phone and run `bash selftest.sh`. It prints how long each step takes, plus the camera, lens and other details of a few photos.

## Known limitations

- **Only macOS and Google Chrome have been tested.** Other Chromium browsers may work but are not set up by the installer.
- **Edits made on the phone are probably not included.** The camera roll stores the original shot, and Photos keeps edits such as crops and filters separately. This has not been fully verified yet.
- **iCloud "Optimize iPhone Storage":** older photos whose full versions live only in iCloud may not appear.
- **Videos** show a single frame provided by the phone.
- **Whether HEIC stays HEIC is not verified yet.** v0.2 uses Apple's camera protocol; with the iPhone's Settings → Photos → Transfer to Mac or PC set to "Automatic", photos may arrive as JPEG. If exports are not HEIC, choose "Keep Originals".
- **The whole photo catalog is read before the first page shows**, so the first screen may be slower than v0.1 on large libraries.
- The interface is Chinese-only for now.

## Uninstall

1. In the downloaded folder, run `bash uninstall.sh`. It removes the helper, its cache, and its log. Your exported photos are not touched.
2. Remove the extension in `chrome://extensions`.

## How it works

```
Chrome tab (extension page)
   │  Chrome Native Messaging
   ▼
Helper (small Swift program, runs only while the tab is open)
   │  Apple ImageCaptureCore (the framework behind Image Capture)
   ▼
iPhone camera roll, read-only
```

The full reasoning is in [docs/DESIGN.md](docs/DESIGN.md): why a browser tab, why v0.1 used AFC and v0.2 moved to ImageCaptureCore, how the first screen is kept fast, and what is planned next. Notes for AI assistants and developers are in [AGENTS.md](AGENTS.md).

## Questions, bugs, ideas

- **Bug or problem:** [open an issue](https://github.com/songxiaofeng1981/iphone-photos-chrome/issues/new/choose). Please include the output of `bash selftest.sh` and the log file `~/Library/Logs/iPhonePhotosHelper.log`, your macOS version, iPhone model, and iOS version.
- **Idea or question:** issues are welcome too, in English or Chinese.
- **Code:** see [CONTRIBUTING.md](CONTRIBUTING.md). You can develop without an iPhone using the built-in mock device.

## License

[MIT](LICENSE)
