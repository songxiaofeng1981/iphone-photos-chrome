// Where photos come from: a real iPhone (ImageCaptureCore, see Phone.swift) or a local folder that pretends to be one.
// 照片从哪里来：真 iPhone（ImageCaptureCore，见 Phone.swift），或者一个假装成手机的本地文件夹。

import AVFoundation
import Foundation
import ImageIO

protocol PhotoSource: AnyObject {
    /// {"state": "ready" | "nodevice" | "locked" | "error", ...} as the extension expects.
    /// 返回插件需要的状态字典。
    func status() -> [String: Any]
    /// Identifies the connected phone, used in cache keys. / 当前手机的标识，用于缓存键。
    var serial: String { get }
    /// Every photo and video file, waiting for the phone to finish listing them.
    /// 全部照片和视频文件；会等手机把目录列完。
    func allFiles() throws -> [PhoneFile]
    func thumbnail(_ item: Item) throws -> (Data?, ThumbMeta)
    func preview(_ item: Item) throws -> Data?
    func read(_ file: PhoneFile, offset: Int64, length: Int64) throws -> Data
}

extension PhotoSource {
    func readAll(_ file: PhoneFile) throws -> Data {
        var data = Data(capacity: Int(file.size))
        var offset: Int64 = 0
        while offset < file.size {
            let part = try read(file, offset: offset, length: min(readChunk, file.size - offset))
            if part.isEmpty { break }
            data.append(part)
            offset += Int64(part.count)
        }
        return data
    }
}

/// First frame of a movie as a JPEG. / 视频第一帧，输出 JPEG。
func videoFrame(_ url: URL, maxPixel: Int, maxBytes: Int? = nil) -> (Data, Int, Int)? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true     // 竖拍视频转正
    generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
    guard let image = try? generator.copyCGImage(at: .zero, actualTime: nil),
          let data = encodeJPEG(image, maxBytes: maxBytes) else { return nil }
    return (data, image.width, image.height)
}

// MARK: - Mock phone (a local folder with a DCIM subfolder) / 模拟手机（含 DCIM 子文件夹的本地文件夹）

final class MockSource: PhotoSource {
    let root: URL
    init(root: String) { self.root = URL(fileURLWithPath: root) }

    var serial: String { "mock" }

    func status() -> [String: Any] {
        guard fm.fileExists(atPath: root.appendingPathComponent("DCIM").path) else {
            return ["state": "error", "message": "模拟文件夹里没有 DCIM：\(root.path)"]
        }
        return ["state": "ready", "serial": serial, "name": "模拟 iPhone（本地文件夹）", "model": "Mock", "ios": "-"]
    }

    func url(_ file: PhoneFile) -> URL { file.handle as! URL }

    func allFiles() throws -> [PhoneFile] {
        let dcim = root.appendingPathComponent("DCIM")
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        guard let walker = fm.enumerator(at: dcim, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            throw HelperError("error", "无法读取 \(dcim.path)")
        }
        var files: [PhoneFile] = []
        while let url = walker.nextObject() as? URL {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let rel = String(url.path.dropFirst(root.path.count))
            files.append(PhoneFile(path: rel, name: url.lastPathComponent, size: Int64(v.fileSize ?? 0),
                                   date: v.creationDate ?? v.contentModificationDate ?? Date(), handle: url as NSURL))
        }
        return files
    }

    func thumbnail(_ item: Item) throws -> (Data?, ThumbMeta) {
        var meta = ThumbMeta()
        let u = url(item.main)
        if item.isVideo {
            guard let (data, w, h) = videoFrame(u, maxPixel: thumbPx) else { throw HelperError("error", "无法读取视频第一帧") }
            meta.width = w; meta.height = h; meta.via = "video-frame"
            return (data, meta)
        }
        guard let source = CGImageSourceCreateWithURL(u as CFURL, nil), let data = jpeg(from: source, maxPixel: thumbPx) else {
            throw HelperError("error", "无法解码图片")
        }
        (meta.width, meta.height, meta.taken) = imageInfo(source)
        meta.via = "imageio"
        return (data, meta)
    }

    func preview(_ item: Item) throws -> Data? {
        let u = url(item.main)
        if item.isVideo { return videoFrame(u, maxPixel: previewPx, maxBytes: previewMaxBytes)?.0 }
        guard let source = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
        return jpeg(from: source, maxPixel: previewPx, maxBytes: previewMaxBytes)
    }

    func read(_ file: PhoneFile, offset: Int64, length: Int64) throws -> Data {
        Thread.sleep(forTimeInterval: 0.005)   // 模拟数据线的一点延迟
        let handle = try FileHandle(forReadingFrom: url(file))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: Int(length)) ?? Data()
    }
}
