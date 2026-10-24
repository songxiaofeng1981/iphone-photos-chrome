// A real iPhone through ImageCaptureCore, the framework Apple's Image Capture app uses.
// macOS handles "Trust This Computer"; the helper only reads. Nothing on the phone is changed or deleted.
// 通过 ImageCaptureCore 读取真 iPhone，苹果“图像捕捉”App 用的就是它。
// “信任此电脑”由 macOS 处理；助手只读，不修改、不删除手机上的任何东西。
//
// ImageCaptureCore calls back on the main thread, so all its state lives there.
// Requests run on worker threads and hop to the main thread to read that state.
// ImageCaptureCore 在主线程回调，所以它的状态都只在主线程读写；请求在工作线程执行，需要时切到主线程读取。

import Foundation
import ImageCaptureCore
import ImageIO

final class PhoneSource: NSObject, PhotoSource, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    private let browser = ICDeviceBrowser()
    private let startedAt = Date()
    // Main thread only / 只在主线程访问
    private var camera: ICCameraDevice?
    private var sessionOpen = false
    private var sessionError: String?
    private var catalogDone = false

    func start() {
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
    }

    private func onMain<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }

    private func isApple(_ device: ICDevice) -> Bool {
        let kind = (device.productKind ?? "") + " " + (device.name ?? "")
        return ["iPhone", "iPad", "iPod"].contains { kind.localizedCaseInsensitiveContains($0) }
    }

    // MARK: status

    var serial: String {
        onMain { camera.map { $0.persistentIDString ?? $0.serialNumberString ?? $0.name ?? "camera" } ?? "" }
    }

    func status() -> [String: Any] {
        // Devices already plugged in are reported shortly after the browser starts. / 已插着的设备会在启动后很快报上来。
        let settle = 1.5 - Date().timeIntervalSince(startedAt)
        if settle > 0, onMain({ camera == nil }) { Thread.sleep(forTimeInterval: settle) }
        return onMain {
            guard let cam = camera else { return ["state": "nodevice"] }
            if cam.isAccessRestrictedAppleDevice { return ["state": "locked"] }
            // A finished catalog means the phone is readable, whatever an earlier attempt said.
            // 目录已经列完就说明能读，不管之前的尝试报过什么错。
            if !catalogDone, let err = sessionError { return ["state": "error", "message": err] }
            return ["state": "ready", "serial": cam.persistentIDString ?? cam.serialNumberString ?? cam.name ?? "camera",
                    "name": cam.name ?? "iPhone", "model": cam.productKind ?? "", "ios": "-"]
        }
    }

    // MARK: listing

    func allFiles() throws -> [PhoneFile] {
        let deadline = Date().addingTimeInterval(300)
        var lastLog = Date.distantPast
        while true {
            let (present, restricted, done, percent) = onMain {
                (camera != nil, camera?.isAccessRestrictedAppleDevice ?? false, catalogDone, camera?.contentCatalogPercentCompleted ?? 0)
            }
            guard present else { throw HelperError.deviceLost }
            if restricted { throw HelperError("locked", "请解锁 iPhone") }
            if done { break }
            if Date() > deadline { throw HelperError("error", "iPhone 照片目录读取超时") }
            if Date().timeIntervalSince(lastLog) > 3 { log("waiting for catalog \(percent)%"); lastLog = Date() }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return onMain {
            (camera?.mediaFiles ?? []).compactMap { item -> PhoneFile? in
                guard let file = item as? ICCameraFile, let name = file.name else { return nil }
                var parts = [name]
                var folder = file.parentFolder
                while let f = folder {
                    if let n = f.name, !n.isEmpty { parts.insert(n, at: 0) }
                    folder = f.parentFolder
                }
                let date = file.exifCreationDate ?? file.creationDate ?? file.fileCreationDate ?? Date(timeIntervalSince1970: 0)
                return PhoneFile(path: "/" + parts.joined(separator: "/"), name: name, size: Int64(file.fileSize), date: date, handle: file)
            }
        }
    }

    private func cameraFile(_ file: PhoneFile) throws -> ICCameraFile {
        guard onMain({ camera != nil }) else { throw HelperError.deviceLost }
        return file.handle as! ICCameraFile
    }

    private func failure(_ error: Error?, _ what: String) -> HelperError {
        if onMain({ camera == nil }) { return .deviceLost }
        return HelperError("error", "\(what)：\(error.map { "\($0.localizedDescription)" } ?? "超时")")
    }

    // MARK: thumbnails, preview, reading

    func thumbnail(_ item: Item) throws -> (Data?, ThumbMeta) {
        let file = try cameraFile(item.main)
        var meta = ThumbMeta()
        let w = file.width, h = file.height
        if w > 0 && h > 0 {
            let rotated = file.orientation.rawValue >= 5
            (meta.width, meta.height) = rotated ? (h, w) : (w, h)
        }
        if let taken = file.exifCreationDate { meta.taken = exifStamp.string(from: taken) }
        let result: (Data?, Error?)? = wait(timeout: 60) { done in
            file.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: thumbPx]) { data, error in done((data, error)) }
        }
        guard let (data, error) = result, let data else { throw failure(result?.1, "读取缩略图失败") }
        _ = error
        meta.via = "device"
        return (data, meta)
    }

    func preview(_ item: Item) throws -> Data? {
        if item.isVideo {
            // The phone renders a frame for movies. / 视频由手机生成一帧画面。
            let file = try cameraFile(item.main)
            let result: (Data?, Error?)? = wait(timeout: 60) { done in
                file.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: previewPx]) { data, error in done((data, error)) }
            }
            guard let data = result?.0 else { throw failure(result?.1, "读取视频画面失败") }
            if data.count <= previewMaxBytes { return data }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return jpeg(from: source, maxPixel: previewPx, maxBytes: previewMaxBytes)
        }
        guard item.main.size <= photoReadMaxBytes else { return nil }
        let data = try readAll(item.main)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return jpeg(from: source, maxPixel: previewPx, maxBytes: previewMaxBytes)
    }

    func read(_ file: PhoneFile, offset: Int64, length: Int64) throws -> Data {
        let cf = try cameraFile(file)
        let result: (Data?, Error?)? = wait(timeout: 120) { done in
            cf.requestReadData(atOffset: off_t(offset), length: off_t(length)) { data, error in done((data, error)) }
        }
        guard let data = result?.0 else { throw failure(result?.1, "读取 \(file.name) 失败") }
        return data
    }

    // MARK: - ICDeviceBrowserDelegate

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let cam = device as? ICCameraDevice else { return }
        log("device added: \(cam.name ?? "?") (\(cam.productKind ?? "?"))")
        // Prefer an iPhone/iPad over other cameras or card readers. / 优先选 iPhone/iPad，而不是其他相机或读卡器。
        if let current = camera, isApple(current) || !isApple(cam) { return }
        if let current = camera { current.requestCloseSession() }
        camera = cam
        sessionOpen = false; sessionError = nil; catalogDone = false
        cam.delegate = self
        openSession(cam)
    }

    /// The phone often reports "locked" for a moment right after it is plugged in, and opening the session then
    /// fails with -9943 "Please unlock". That is not an error: wait for the unlock and open again.
    /// 手机刚插上时常会短暂报告“已锁定”，这时打开会话会失败（-9943“请解锁”）。这不算出错：等解锁后再打开一次。
    private func openSession(_ cam: ICCameraDevice) {
        cam.requestOpenSession(options: [:]) { error in
            DispatchQueue.main.async {
                guard self.camera === cam else { return }
                if let error {
                    let locked = (error as NSError).code == -9943 || cam.isAccessRestrictedAppleDevice
                    self.sessionError = locked ? nil : error.localizedDescription
                    log("open session failed\(locked ? " (locked, will retry after unlock)" : ""): \(error)", "WARNING")
                } else {
                    self.sessionOpen = true; self.sessionError = nil
                    log("session open: \(cam.name ?? "?")")
                }
            }
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if device === camera { forget("removed from browser") }
    }

    private func forget(_ why: String) {
        log("device detached (\(why))")
        camera = nil; sessionOpen = false; sessionError = nil; catalogDone = false
    }

    // MARK: - ICDeviceDelegate

    func didRemove(_ device: ICDevice) { if device === camera { forget("removed") } }
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {}
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        if device === camera { sessionOpen = false }
    }

    // MARK: - ICCameraDeviceDelegate

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        guard device === camera else { return }
        catalogDone = true; sessionOpen = true; sessionError = nil
        log("catalog complete: \(device.mediaFiles?.count ?? 0) files")
    }
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        log("access restriction removed (unlocked)")
        guard let cam = camera, device === cam else { return }
        sessionError = nil
        // If the earlier open failed because the phone was locked, try again now. / 之前因锁屏没打开会话的，现在重试。
        if !sessionOpen && !catalogDone {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if self.camera === cam && !self.sessionOpen && !self.catalogDone { self.openSession(cam) }
            }
        }
    }
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) { log("access restriction enabled (locked)") }

    // MARK: - Self test extras / 自测附加信息

    /// Metadata of one file, for checking what the phone exposes (camera, lens, software…).
    /// 读取一个文件的元数据，用来看手机提供了哪些信息（机型、镜头、软件……）。
    func metadata(_ file: PhoneFile) -> [String: Any]? {
        guard let cf = file.handle as? ICCameraFile else { return nil }
        let result: [AnyHashable: Any]?? = wait(timeout: 30) { done in
            cf.requestMetadataDictionary(options: nil) { dict, _ in done(dict) }
        }
        guard let dict = result ?? nil else { return nil }
        var out: [String: Any] = [:]
        for (k, v) in dict { out["\(k)"] = v }
        return out
    }
}
