// iPhone Photos helper / iPhone 照片读取助手 (Chrome Native Messaging host)
//
// Chrome starts it when the photo page opens and it exits when the page closes. It only reads the phone:
// lists photos, makes thumbnails and previews (cached in ~/Library/Caches/iPhonePhotosHelper), and copies
// original files to ~/Downloads/iPhone YYYY-MM-DD/. Same protocol as the earlier Python helper (host.py).
// Chrome 打开照片页时启动，关掉页面就退出。只读手机：列出照片、生成缩略图和预览（缓存在
// ~/Library/Caches/iPhonePhotosHelper），把原文件复制到 ~/Downloads/iPhone YYYY-MM-DD/。协议和之前的 Python 版完全一样。
//
//   iphone-photos-helper --selftest                  test with the connected iPhone / 用插着的 iPhone 自测
//   iphone-photos-helper --selftest --mock <folder>  test with a folder that has a DCIM subfolder / 用本地文件夹模拟手机

import CryptoKit
import Foundation

// MARK: - Request handling / 处理请求

final class Service {
    let source: PhotoSource
    private let lock = NSLock()
    private var snapshot: [Item]?
    private var items: [String: Item] = [:]
    private var building: [String: DispatchSemaphore] = [:]
    init(source: PhotoSource) { self.source = source }

    func reset() {
        lock.lock(); snapshot = nil; items = [:]; lock.unlock()
    }

    func item(_ id: String) throws -> Item {
        lock.lock(); defer { lock.unlock() }
        guard let it = items[id] else { throw HelperError("unknown_item", "这张照片不在当前列表里，请刷新") }
        return it
    }

    /// One page of items, newest first. The cursor is the offset into a snapshot taken on the first page.
    /// 一页照片，新的在前。cursor 是在第一页时拍下的快照里的位置。
    func list(cursor: Int?, limit: Int) throws -> ([Item], Int?) {
        lock.lock()
        var all = cursor == nil ? nil : snapshot
        lock.unlock()
        if all == nil {
            let t0 = Date()
            let built = groupItems(try source.allFiles())
            log(String(format: "listed %d items in %.2fs", built.count, Date().timeIntervalSince(t0)))
            lock.lock(); snapshot = built; for it in built { items[it.id] = it }; lock.unlock()
            all = built
        }
        let start = min(cursor ?? 0, all!.count)
        let page = Array(all![start..<min(start + limit, all!.count)])
        let next = start + page.count
        return (page, next < all!.count ? next : nil)
    }

    private func cachePaths(_ item: Item) -> (thumb: URL, preview: URL, meta: URL) {
        let digest = Insecure.SHA1.hash(data: Data("\(source.serial)|\(item.id)|\(item.size)".utf8))
        let key = String(digest.map { String(format: "%02x", $0) }.joined().prefix(24))
        let dir = cacheDir.appendingPathComponent("thumbs/\(key.prefix(2))")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.appendingPathComponent("\(key).jpg"), dir.appendingPathComponent("\(key)_p.jpg"), dir.appendingPathComponent("\(key).json"))
    }

    /// Runs `body` once per key even when the page asks twice at the same time. / 同一个键同时被请求两次时只执行一次。
    private func once(_ key: String, _ body: () -> Void) {
        lock.lock()
        if let busy = building[key] {
            lock.unlock(); busy.wait(); busy.signal(); return
        }
        let gate = DispatchSemaphore(value: 0)
        building[key] = gate
        lock.unlock()
        body()
        lock.lock(); building[key] = nil; lock.unlock()
        gate.signal()
    }

    func thumb(_ id: String) throws -> [String: Any] {
        let it = try item(id)
        let p = cachePaths(it)
        func cached() -> ThumbMeta? {
            guard let raw = try? Data(contentsOf: p.meta),
                  let d = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return nil }
            let m = ThumbMeta(json: d)
            return m.noThumb || fm.fileExists(atPath: p.thumb.path) ? m : nil
        }
        if let m = cached() { return thumbResult(id, p.thumb, m, cached: true) }
        var thrown: Error?
        once("t:" + p.meta.path) {
            if cached() != nil { return }
            let t0 = Date()
            var meta = ThumbMeta()
            do {
                let (data, m) = try source.thumbnail(it)
                meta = m
                if let data { try data.write(to: p.thumb, options: .atomic) } else { meta.noThumb = true }
            } catch let e as HelperError where e.code == "device_lost" || e.code == "locked" {
                thrown = e; return
            } catch {
                log("thumbnail failed (\(it.main.name)): \(error)", "WARNING")
                meta.noThumb = true; meta.error = String("\(error)".prefix(200))
            }
            if let raw = try? JSONSerialization.data(withJSONObject: meta.json) { try? raw.write(to: p.meta, options: .atomic) }
            log(String(format: "thumb %@ %.1fMB %.2fs via %@", it.main.name, Double(it.main.size) / 1e6, Date().timeIntervalSince(t0), meta.via))
        }
        if let thrown { throw thrown }
        return thumbResult(id, p.thumb, cached() ?? { var m = ThumbMeta(); m.noThumb = true; return m }(), cached: false)
    }

    private func thumbResult(_ id: String, _ url: URL, _ m: ThumbMeta, cached: Bool) -> [String: Any] {
        let data = m.noThumb ? nil : try? Data(contentsOf: url)
        var r: [String: Any] = ["id": id, "thumb": data?.base64EncodedString() ?? NSNull(), "cached": cached,
                                "taken": m.taken ?? NSNull(), "w": m.width ?? NSNull(), "h": m.height ?? NSNull()]
        if m.noThumb || data == nil { r["noThumb"] = true }
        return r
    }

    func preview(_ id: String) throws -> [String: Any] {
        let it = try item(id)
        let p = cachePaths(it)
        var thrown: Error?
        if !fm.fileExists(atPath: p.preview.path) {
            once("p:" + p.preview.path) {
                if fm.fileExists(atPath: p.preview.path) { return }
                do {
                    if let data = try source.preview(it) { try data.write(to: p.preview, options: .atomic) }
                } catch let e as HelperError where e.code == "device_lost" {
                    thrown = e
                } catch {
                    log("preview failed \(it.main.name): \(error)", "WARNING")
                }
            }
        }
        if let thrown { throw thrown }
        let data = try? Data(contentsOf: p.preview)
        return ["id": id, "data": data?.base64EncodedString() ?? NSNull()]
    }

    /// Copies the original files (Live Photo movie included) to ~/Downloads/iPhone YYYY-MM-DD/.
    /// Files already there with the same size are skipped; name clashes get " (1)", " (2)"…
    /// 把原文件（含实况照片的 MOV）复制到“下载 / iPhone 日期”。已存在且大小相同的跳过；重名的加 " (1)"、" (2)"……
    func export(_ ids: [String], progress: ([String: Any]) -> Void) throws -> [String: Any] {
        var files: [PhoneFile] = []
        for id in ids {
            guard let it = try? item(id) else {
                throw HelperError("unknown_item", "找不到 \((id as NSString).lastPathComponent)，请刷新后重选")
            }
            files += it.files
        }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let dest = downloadsDir.appendingPathComponent("iPhone \(day.string(from: Date()))")
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let total = max(files.reduce(0) { $0 + $1.size }, 1)
        var done: Int64 = 0, skipped = 0, lastEmit = Date.distantPast
        var written: [String] = []
        for (index, f) in files.enumerated() {
            var out = dest.appendingPathComponent(f.name)
            if let size = (try? fm.attributesOfItem(atPath: out.path))?[.size] as? Int64, size == f.size {
                skipped += 1; done += f.size; continue
            }
            var n = 1
            while fm.fileExists(atPath: out.path) {
                out = dest.appendingPathComponent("\(f.stem) (\(n)).\((f.name as NSString).pathExtension)")
                n += 1
            }
            let part = out.appendingPathExtension("part")
            fm.createFile(atPath: part.path, contents: nil)
            let handle = try FileHandle(forWritingTo: part)
            do {
                var offset: Int64 = 0
                while offset < f.size {
                    let chunk = try source.read(f, offset: offset, length: min(readChunk, f.size - offset))
                    if chunk.isEmpty { break }
                    handle.write(chunk)
                    offset += Int64(chunk.count); done += Int64(chunk.count)
                    if Date().timeIntervalSince(lastEmit) > 0.15 {
                        lastEmit = Date()
                        progress(["index": index + 1, "count": files.count, "file": f.name, "done": done, "total": total])
                    }
                }
                try handle.close()
            } catch {
                try? handle.close(); try? fm.removeItem(at: part)
                throw error
            }
            try fm.moveItem(at: part, to: out)
            try? fm.setAttributes([.modificationDate: f.date, .creationDate: f.date], ofItemAtPath: out.path)
            written.append(out.path)
        }
        progress(["index": files.count, "count": files.count, "file": "", "done": total, "total": total])
        log("exported \(ids.count) items, \(written.count) files written, \(skipped) skipped -> \(dest.path)")
        return ["dir": dest.path, "files": written, "skipped": skipped, "count": ids.count]
    }

    func handle(_ msg: [String: Any]) {
        let rid = msg["rid"] ?? NSNull()
        let cmd = msg["cmd"] as? String ?? ""
        do {
            let result: [String: Any]
            switch cmd {
            case "hello": result = ["version": helperVersion]
            case "status": result = source.status()
            case "list":
                let limit = max(1, min((msg["limit"] as? Int) ?? 40, 200))
                let (page, next) = try list(cursor: msg["cursor"] as? Int, limit: limit)
                result = ["items": page.map(\.json), "cursor": next ?? NSNull()]
            case "refresh": reset(); result = [:]
            case "thumb": result = try thumb(msg["id"] as? String ?? "")
            case "preview": result = try preview(msg["id"] as? String ?? "")
            case "export":
                result = try export(msg["ids"] as? [String] ?? []) { p in
                    send(p.merging(["event": "progress", "rid": rid]) { a, _ in a })
                }
            case "reveal":
                let path = ((msg["path"] as? String ?? "") as NSString).expandingTildeInPath
                if path.hasPrefix(home.path + "/"), fm.fileExists(atPath: path) {
                    let open = Process()
                    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    open.arguments = [path]
                    try? open.run()
                }
                result = [:]
            default: throw HelperError("bad_cmd", "未知命令 \(cmd)")
            }
            send(["rid": rid, "ok": true, "result": result])
        } catch let e as HelperError {
            if e.code == "device_lost" { reset() }
            let code = e.code == "locked" ? "device_lost" : e.code   // 锁屏时让页面回到状态页 / back to the status screen
            send(["rid": rid, "ok": false, "code": code, "error": e.message])
        } catch {
            log("command \(cmd) failed: \(error)", "ERROR")
            send(["rid": rid, "ok": false, "code": "error", "error": "\(error)"])
        }
    }
}

// MARK: - Self test (no Chrome needed) / 自测（不需要 Chrome）

func selftest(_ service: Service) -> Int32 {
    let source = service.source
    print("iPhone 照片读取助手 \(helperVersion)（Swift + ImageCaptureCore）")
    print("正在查找 iPhone…")
    var st: [String: Any] = [:]
    var lastHint = ""
    for _ in 0..<60 {
        st = source.status()
        if st["state"] as? String == "ready" { break }
        let hint = ["nodevice": "没检测到 iPhone，请用数据线连接", "locked": "请解锁 iPhone；第一次连接还要在手机上点「信任」"][st["state"] as? String ?? ""]
            ?? (st["message"] as? String ?? "\(st["state"] ?? "?")")
        if hint != lastHint { print("  " + hint); lastHint = hint }
        Thread.sleep(forTimeInterval: 2)
    }
    guard st["state"] as? String == "ready" else { print("超时，退出。"); return 1 }
    print("已连接：\(st["name"] ?? "?")（\(st["model"] ?? "?")）")

    do {
        let t0 = Date()
        let (page, _) = try service.list(cursor: nil, limit: 20)
        let all = try service.list(cursor: 0, limit: 1_000_000).0
        let t1 = Date()
        print(String(format: "读取照片目录用时 %.2fs，共 %d 项（实况照片 %d 项）", t1.timeIntervalSince(t0), all.count, all.filter { $0.live != nil }.count))
        var byExt: [String: Int] = [:]
        for it in all { byExt[it.main.ext.uppercased(), default: 0] += 1 }
        print("按格式：" + byExt.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: "，"))
        let stamp = DateFormatter(); stamp.dateFormat = "MM-dd HH:mm"
        for it in page.prefix(6) {
            print(String(format: "  %-16@ %@  %5.1f MB%@", it.main.name, stamp.string(from: it.main.date), Double(it.size) / 1e6, it.live != nil ? "  实况" : ""))
        }
        let t2 = Date()
        var ok = 0, cachedCount = 0
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: page.count) { i in
            if let r = try? service.thumb(page[i].id) {
                lock.lock()
                if !(r["thumb"] is NSNull) { ok += 1 }
                if r["cached"] as? Bool == true { cachedCount += 1 }
                lock.unlock()
            }
        }
        print(String(format: "生成 %d/%d 张缩略图用时 %.2fs（其中 %d 张来自缓存）", ok, page.count, Date().timeIntervalSince(t2), cachedCount))
        if let first = page.first(where: { !$0.isVideo }) ?? page.first {
            let t3 = Date()
            let pv = try service.preview(first.id)
            let kb = ((pv["data"] as? String)?.count ?? 0) * 3 / 4 / 1024
            print(String(format: "放大预览 %@ 用时 %.2fs，大小 %d KB", first.main.name, Date().timeIntervalSince(t3), kb))
        }
        if let phone = source as? PhoneSource {
            print("前 5 张照片的元数据（用来判断能做哪些分类）：")
            for it in page.filter({ !$0.isVideo }).prefix(5) {
                let m = phone.metadata(it.main) ?? [:]
                let tiff = m["{TIFF}"] as? [String: Any] ?? [:]
                let exif = m["{Exif}"] as? [String: Any] ?? [:]
                let gps = m["{GPS}"] != nil
                print("  \(it.main.name)：机型 \(tiff["Make"] ?? "-") \(tiff["Model"] ?? "")，镜头 \(exif["LensModel"] ?? "-")，软件 \(tiff["Software"] ?? "-")，\(m["PixelWidth"] ?? "?")×\(m["PixelHeight"] ?? "?")，GPS \(gps ? "有" : "无")")
            }
        }
    } catch let e as HelperError {
        print("出错：\(e.message)"); return 1
    } catch {
        print("出错：\(error)"); return 1
    }
    print("缓存目录：\(cacheDir.path)\n日志：\(logURL.path)")
    return 0
}

// MARK: - Entry / 入口

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
if args.contains("--version") { print(helperVersion); exit(0) }
let selftestMode = args.contains("--selftest")
var mockDir: String?
if let i = args.firstIndex(of: "--mock"), i + 1 < args.count { mockDir = args[i + 1] }
if mockDir == nil { mockDir = ProcessInfo.processInfo.environment["IPHONE_PHOTOS_MOCK_DIR"] }
let mockFile = home.appendingPathComponent("Library/Application Support/\(appName)/mock_dir")
if mockDir == nil, let text = try? String(contentsOf: mockFile, encoding: .utf8) {
    // 开发用：写入一个本地文件夹路径，Chrome 启动的助手就会用模拟手机 / dev only
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { mockDir = trimmed }
}

if !selftestMode {
    // Chrome passes the caller's origin as the first argument. / Chrome 会把调用方的 origin 作为参数传入。
    let allowed = args.dropFirst().contains { arg in
        allowedExtensionIDs.contains { arg == "chrome-extension://\($0)/" || arg == "chrome-extension://\($0)" }
    }
    guard allowed else { fputs("Rejected caller origin\n", stderr); exit(2) }
}

logToConsole = selftestMode
let source: PhotoSource
if let dir = mockDir {
    source = MockSource(root: dir)
} else {
    let phone = PhoneSource()
    phone.start()
    source = phone
}
let service = Service(source: source)

if selftestMode {
    Thread.detachNewThread { exit(selftest(service)) }
} else {
    log("helper \(helperVersion) started (pid \(getpid()))\(mockDir.map { " mock=\($0)" } ?? "")")
    // Requests run in parallel (at most 4) so a big export never blocks thumbnails.
    // 请求并行处理（最多 4 个），导出大文件时不会卡住缩略图。
    Thread.detachNewThread {
        let workers = DispatchQueue(label: "iphone-photos.workers", attributes: .concurrent)
        let slots = DispatchSemaphore(value: 4)
        let inFlight = DispatchGroup()
        while let header = readExactly(4) {
            let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
            guard length > 0, length <= 4 * 1024 * 1024, let body = readExactly(Int(length)) else { break }
            guard let msg = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                log("bad message", "ERROR"); continue
            }
            slots.wait()
            inFlight.enter()
            workers.async {
                service.handle(msg)
                slots.signal()
                inFlight.leave()
            }
        }
        log("chrome disconnected, exiting")
        _ = inFlight.wait(timeout: .now() + 2)
        exit(0)
    }
}
RunLoop.main.run()
