// Shared pieces of the iPhone Photos helper: messaging, logging, the item model and image helpers.
// iPhone 照片读取助手的公共部分：消息收发、日志、照片条目模型、图片处理。

import Foundation
import ImageIO
import UniformTypeIdentifiers

let helperVersion = "0.2.1"
let allowedExtensionIDs: Set<String> = ["endldjnpicempoibdmlndkiinmmekggn"]
let appName = "iPhonePhotosHelper"
let fm = FileManager.default
// Like Python's Path.home(): honour $HOME, so tests can run in a temporary home. / 和 Python 的 Path.home() 一样认 $HOME，便于在临时目录里测试。
let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory())
let cacheDir = home.appendingPathComponent("Library/Caches/\(appName)")
let logURL = home.appendingPathComponent("Library/Logs/\(appName).log")
let downloadsDir = home.appendingPathComponent("Downloads")

let photoExts: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "gif", "webp", "dng", "tif", "tiff"]
let videoExts: Set<String> = ["mov", "mp4", "m4v"]
let mainPriority = ["heic", "heif", "jpg", "jpeg", "png", "gif", "webp", "tif", "tiff", "dng"]

let thumbPx = 360
let previewPx = 1600
let previewMaxBytes = 650_000            // Native Messaging 单条消息上限 1 MB，base64 后要留余量
let photoReadMaxBytes: Int64 = 120 * 1024 * 1024
let readChunk: Int64 = 4 * 1024 * 1024

struct HelperError: Error, CustomStringConvertible {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
    var description: String { "\(code): \(message)" }
    static let deviceLost = HelperError("device_lost", "iPhone 未连接")
}

// MARK: - Logging / 日志

let logLock = NSLock()
var logToConsole = false
let logStamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
    return f
}()

func log(_ message: String, _ level: String = "INFO") {
    logLock.lock()
    defer { logLock.unlock() }
    if logToConsole { fputs(message + "\n", stderr) }
    try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 1_000_000 {
        let old = logURL.appendingPathExtension("1")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: logURL, to: old)
    }
    let line = "\(logStamp.string(from: Date())) \(level) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: logURL)
    }
}

// MARK: - Native Messaging framing / 消息帧：4 字节小端长度 + JSON

let outputLock = NSLock()

func send(_ object: [String: Any]) {
    var payload = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    if payload.count > 1_000_000 {
        log("message too large (\(payload.count) bytes), dropped", "ERROR")
        payload = (try? JSONSerialization.data(withJSONObject: ["rid": object["rid"] ?? NSNull(), "ok": false,
                                                               "code": "too_large", "error": "返回数据超过 1 MB 上限"])) ?? Data()
    }
    var length = UInt32(payload.count).littleEndian
    let header = withUnsafeBytes(of: &length) { Data($0) }
    outputLock.lock()
    defer { outputLock.unlock() }
    FileHandle.standardOutput.write(header + payload)
}

func readExactly(_ count: Int) -> Data? {
    var result = Data()
    while result.count < count {
        guard let part = try? FileHandle.standardInput.read(upToCount: count - result.count), !part.isEmpty else { return nil }
        result.append(part)
    }
    return result
}

// MARK: - Items / 照片条目

/// One file on the phone. `handle` is an ICCameraFile for a real phone or a URL for the mock folder.
/// 手机上的一个文件。真机时 handle 是 ICCameraFile，模拟时是本地 URL。
struct PhoneFile {
    let path: String          // "/DCIM/100APPLE/IMG_0001.HEIC"
    let name: String
    let size: Int64
    let date: Date
    let handle: AnyObject
    var ext: String { (name as NSString).pathExtension.lowercased() }
    var folder: String { (path as NSString).deletingLastPathComponent }
    var stem: String { (name as NSString).deletingPathExtension }
}

/// What the grid shows as one tile: a photo or video, plus its Live Photo movie and other formats of the same shot.
/// 照片墙上的一格：一张照片或一段视频，加上实况照片的 MOV 和同一张照片的其他格式。
final class Item {
    let main: PhoneFile
    let live: PhoneFile?
    let extra: [PhoneFile]
    init(main: PhoneFile, live: PhoneFile?, extra: [PhoneFile]) { self.main = main; self.live = live; self.extra = extra }

    var id: String { main.path }
    var files: [PhoneFile] { [main] + (live.map { [$0] } ?? []) + extra }
    var size: Int64 { files.reduce(0) { $0 + $1.size } }
    var isVideo: Bool { videoExts.contains(main.ext) }

    var json: [String: Any] {
        ["id": id, "name": main.name, "ext": main.ext.uppercased(), "kind": isVideo ? "video" : "photo",
         "live": live != nil, "liveName": live?.name ?? NSNull(), "size": size, "mainSize": main.size,
         "fileCount": files.count, "t": Int64(main.date.timeIntervalSince1970 * 1000)]
    }
}

/// Groups files that share a folder and a base name: photo + movie = Live Photo. Newest first.
/// 同一文件夹、同名的文件归为一组：照片 + 视频 = 实况照片。新的在前。
func groupItems(_ files: [PhoneFile]) -> [Item] {
    var groups: [String: [PhoneFile]] = [:]
    for f in files where photoExts.contains(f.ext) || videoExts.contains(f.ext) {
        groups[f.folder + "/" + f.stem, default: []].append(f)
    }
    var items: [Item] = []
    for (_, group) in groups {
        let photos = group.filter { photoExts.contains($0.ext) }
            .sorted { (mainPriority.firstIndex(of: $0.ext) ?? 99) < (mainPriority.firstIndex(of: $1.ext) ?? 99) }
        let videos = group.filter { videoExts.contains($0.ext) }
        if let main = photos.first {
            items.append(Item(main: main, live: videos.first, extra: Array(photos.dropFirst())))
        } else {
            items += videos.map { Item(main: $0, live: nil, extra: []) }
        }
    }
    return items.sorted { $0.main.date != $1.main.date ? $0.main.date > $1.main.date : $0.main.name > $1.main.name }
}

// MARK: - Images / 图片

struct ThumbMeta {
    var taken: String? = nil   // "2026:09:25 12:28:20", EXIF style / EXIF 格式
    var width: Int? = nil
    var height: Int? = nil
    var via = "-"
    var noThumb = false
    var error: String? = nil

    var json: [String: Any] {
        var d: [String: Any] = ["taken": taken ?? NSNull(), "w": width ?? NSNull(), "h": height ?? NSNull(), "via": via]
        if noThumb { d["noThumb"] = true; d["error"] = error ?? "" }
        return d
    }
    init() {}
    init(json d: [String: Any]) {
        taken = d["taken"] as? String; width = d["w"] as? Int; height = d["h"] as? Int
        via = d["via"] as? String ?? "-"; noThumb = d["noThumb"] as? Bool ?? false; error = d["error"] as? String
    }
}

let exifStamp: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy:MM:dd HH:mm:ss"
    return f
}()

/// Downscaled JPEG with the EXIF orientation applied, kept under `maxBytes` when given.
/// 按 EXIF 方向转正后缩小成 JPEG；给了 maxBytes 时压到这个大小以内。
func jpeg(from source: CGImageSource, maxPixel: Int, maxBytes: Int? = nil) -> Data? {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), options as CFDictionary)
    else { return nil }
    return encodeJPEG(image, maxBytes: maxBytes)
}

func encodeJPEG(_ image: CGImage, maxBytes: Int? = nil) -> Data? {
    var quality = 0.82
    while true {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        if maxBytes == nil || out.length <= maxBytes! || quality <= 0.45 { return out as Data }
        quality -= 0.1
    }
}

/// Size (orientation applied) and capture time read from an image's header.
/// 从图片文件头读出尺寸（已按方向转正）和拍摄时间。
func imageInfo(_ source: CGImageSource) -> (width: Int?, height: Int?, taken: String?) {
    guard let props = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) as? [CFString: Any]
    else { return (nil, nil, nil) }
    let w = props[kCGImagePropertyPixelWidth] as? Int
    let h = props[kCGImagePropertyPixelHeight] as? Int
    let rotated = (props[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
    let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
    let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    let taken = exif?[kCGImagePropertyExifDateTimeOriginal] as? String ?? tiff?[kCGImagePropertyTIFFDateTime] as? String
    return (rotated ? h : w, rotated ? w : h, taken)
}

/// Waits for an asynchronous callback. Never call this on the main thread: ImageCaptureCore needs it.
/// 等待异步回调。不要在主线程调用：主线程要留给 ImageCaptureCore。
func wait<T>(timeout: TimeInterval, _ start: (@escaping (T) -> Void) -> Void) -> T? {
    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var result: T?
    start { value in
        lock.lock(); result = value; lock.unlock()
        done.signal()
    }
    guard done.wait(timeout: .now() + timeout) == .success else { return nil }
    lock.lock(); defer { lock.unlock() }
    return result
}
