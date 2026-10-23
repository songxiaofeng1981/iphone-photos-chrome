#!/usr/bin/env python3
"""iPhone 照片 Chrome 插件的读取助手（Chrome Native Messaging host）。

- 由 Chrome 在照片页打开时启动，页面关闭、连接断开后退出，不常驻。
- 通过 AFC（pymobiledevice3）读取 iPhone 的 /DCIM，只列需要的那一页。
- 缩略图和预览按需生成并缓存在 ~/Library/Caches/iPhonePhotosHelper。
- 导出时把原文件直接写到 ~/Downloads/iPhone YYYY-MM-DD/，不修改、不删除手机上的任何文件。

自测：python host.py --selftest
用本地文件夹模拟手机：python host.py --selftest --mock /path/to/folder（folder 里要有 DCIM 子目录）
"""
import argparse
import asyncio
import hashlib
import io
import json
import logging
import logging.handlers
import os
import posixpath
import struct
import subprocess
import sys
import threading
import time
import base64
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

VERSION = "0.1.0"
APP = "iPhonePhotosHelper"
CACHE_DIR = Path.home() / "Library" / "Caches" / APP
LOG_FILE = Path.home() / "Library" / "Logs" / f"{APP}.log"
DOWNLOADS = Path.home() / "Downloads"
DCIM = "/DCIM"

PHOTO_EXT = {".heic", ".heif", ".jpg", ".jpeg", ".png", ".gif", ".webp", ".dng", ".tif", ".tiff"}
VIDEO_EXT = {".mov", ".mp4", ".m4v"}
MAIN_PRIORITY = [".heic", ".heif", ".jpg", ".jpeg", ".png", ".gif", ".webp", ".tif", ".tiff", ".dng"]

THUMB_PX = 360
PREVIEW_PX = 1600
PREVIEW_MAX_BYTES = 650_000          # Native Messaging 单条消息上限 1 MB，base64 后要留余量
VIDEO_THUMB_MAX_BYTES = 60 * 1024 * 1024
PHOTO_READ_MAX_BYTES = 120 * 1024 * 1024
CHUNK = 4 * 1024 * 1024
READ_CONCURRENCY = 2

# stdout 是和 Chrome 通信的管道，任何库的 print 都会破坏协议，所以把 sys.stdout 指到 stderr
_OUT = sys.stdout.buffer
sys.stdout = sys.stderr

log = logging.getLogger(APP)
POOL = ThreadPoolExecutor(max_workers=3)
_out_lock = threading.Lock()


def setup_logging(console=False):
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    h = logging.handlers.RotatingFileHandler(LOG_FILE, maxBytes=1_000_000, backupCount=2, encoding="utf-8")
    h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    root.addHandler(h)
    if console:
        c = logging.StreamHandler(sys.stderr)
        c.setFormatter(logging.Formatter("%(message)s"))
        log.addHandler(c)
    # pymobiledevice3 的日志太多，只保留警告
    logging.getLogger("pymobiledevice3").setLevel(logging.WARNING)


# ---------------------------------------------------------------- native messaging

def send(msg):
    data = json.dumps(msg, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(data) > 1_000_000:
        log.error("message too large (%d bytes), dropped: %s", len(data), msg.get("rid"))
        data = json.dumps({"rid": msg.get("rid"), "ok": False, "code": "too_large",
                           "error": "返回数据超过 1 MB 上限"}).encode("utf-8")
    with _out_lock:
        _OUT.write(struct.pack("<I", len(data)))
        _OUT.write(data)
        _OUT.flush()


def stdin_reader(loop, queue):
    stdin = sys.stdin.buffer
    while True:
        header = stdin.read(4)
        if len(header) < 4:
            loop.call_soon_threadsafe(queue.put_nowait, None)
            return
        (n,) = struct.unpack("<I", header)
        body = stdin.read(n)
        try:
            msg = json.loads(body.decode("utf-8"))
        except Exception:
            log.exception("bad message")
            continue
        loop.call_soon_threadsafe(queue.put_nowait, msg)


# ---------------------------------------------------------------- images (run in thread pool)

_ORIENT_OPS = {3: 3, 6: 4, 8: 2}   # EXIF orientation -> PIL.Image.Transpose (ROTATE_180 / ROTATE_270 / ROTATE_90)


def _exif_taken(exif_bytes):
    from PIL import Image
    if not exif_bytes:
        return None, None
    try:
        ex = Image.Exif()
        ex.load(exif_bytes)
        return ex.get_ifd(0x8769).get(36867) or ex.get(306), ex.get(274)
    except Exception:
        return None, None


def _heic_fast_thumb(data):
    """用 HEIC 文件里内嵌的小缩略图（iPhone 照片自带），几毫秒即可，不解码 1200 万像素原图。"""
    import pillow_heif
    hf = pillow_heif.open_heif(io.BytesIO(data))
    img = next((im for im in hf if im.info.get("primary")), hf[0])
    taken, orient = _exif_taken(img.info.get("exif"))
    w, h = img.size                       # libheif 已应用旋转后的尺寸
    sizes = img.info.get("thumbnails") or []
    if not sizes:
        return None, taken, (w, h)
    best = max(range(len(sizes)), key=lambda i: sizes[i] or 0)
    th = img.get_thumbnail(best).to_pillow()
    if th.width < 200 and th.height < 200:
        return None, taken, (w, h)
    # 缩略图方向和主图不一致时，按 EXIF 方向补转一次
    if (th.width > th.height) != (w > h) and orient in _ORIENT_OPS:
        th = th.transpose(_ORIENT_OPS[orient])
    return th, taken, (w, h)


def _open_full(data, ext, max_px):
    from PIL import Image, ImageOps
    if ext in (".heic", ".heif"):
        import pillow_heif
        pillow_heif.register_heif_opener()
    im = Image.open(io.BytesIO(data))
    if im.format == "JPEG":
        im.draft("RGB", (max_px, max_px))   # JPEG 可以按比例直接解码小图，很快
    taken = None
    try:
        exif = im.getexif()
        taken = exif.get_ifd(0x8769).get(36867) or exif.get(306)
    except Exception:
        pass
    im = ImageOps.exif_transpose(im)
    return im, taken


def _video_frame(data):
    import av
    with av.open(io.BytesIO(data)) as container:
        for frame in container.decode(video=0):
            return frame.to_image()
    raise ValueError("no video frame")


def _encode(im, px, quality, max_bytes=None):
    im = im.copy()
    im.thumbnail((px, px))
    if im.mode not in ("RGB", "L"):
        im = im.convert("RGB")
    q = quality
    while True:
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=q)
        b = buf.getvalue()
        if not max_bytes or len(b) <= max_bytes or q <= 45:
            return b
        q -= 10


def _atomic_write(path, data):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)


def build_thumb(data, ext, kind, tp, pp, mp):
    """生成网格缩略图。能顺手生成预览图的格式（PNG、视频）一起生成，HEIC/JPEG 的预览留到真正放大时再做。"""
    try:
        path = "full"
        if kind == "video":
            im, taken = _video_frame(data), None
            size = im.size
            _atomic_write(pp, _encode(im, PREVIEW_PX, 82, PREVIEW_MAX_BYTES))
        elif ext in (".heic", ".heif"):
            th, taken, size = _heic_fast_thumb(data)
            if th is not None:
                im, path = th, "embedded"
            else:
                im, taken = _open_full(data, ext, PREVIEW_PX)
                _atomic_write(pp, _encode(im, PREVIEW_PX, 82, PREVIEW_MAX_BYTES))
        elif ext in (".jpg", ".jpeg"):
            im, taken = _open_full(data, ext, THUMB_PX)
            size, path = None, "jpeg-draft"
        else:
            im, taken = _open_full(data, ext, PREVIEW_PX)
            size = im.size
            _atomic_write(pp, _encode(im, PREVIEW_PX, 82, PREVIEW_MAX_BYTES))
        _atomic_write(tp, _encode(im, THUMB_PX, 78))
        meta = {"taken": taken, "w": size[0] if size else None, "h": size[1] if size else None, "via": path}
    except Exception as e:
        log.warning("thumbnail failed (%s): %s", ext, e)
        meta = {"noThumb": True, "error": str(e)[:200]}
    _atomic_write(mp, json.dumps(meta).encode())
    return meta


def build_preview(data, ext, kind, pp):
    if kind == "video":
        im = _video_frame(data)
    else:
        im, _ = _open_full(data, ext, PREVIEW_PX)
    _atomic_write(pp, _encode(im, PREVIEW_PX, 82, PREVIEW_MAX_BYTES))
    return im.size


# ---------------------------------------------------------------- mock AFC (用本地文件夹模拟手机，便于测试界面)

class MockAfc:
    def __init__(self, root):
        self.root = Path(root)
        self._handles = {}

    def _p(self, path):
        return self.root / path.lstrip("/")

    async def listdir(self, path):
        return sorted(os.listdir(self._p(path)))

    async def stat(self, path):
        st = os.stat(self._p(path))
        return {"st_size": st.st_size,
                "st_mtime": datetime.fromtimestamp(st.st_mtime),
                "st_birthtime": datetime.fromtimestamp(getattr(st, "st_birthtime", st.st_mtime))}

    async def get_file_contents(self, path):
        await asyncio.sleep(0.02)
        return self._p(path).read_bytes()

    async def fopen(self, path, mode="r"):
        f = open(self._p(path), "rb")
        self._handles[id(f)] = f
        return id(f)

    async def fread(self, handle, sz):
        return self._handles[handle].read(sz)

    async def fclose(self, handle):
        self._handles.pop(handle).close()

    async def aclose(self):
        pass


# ---------------------------------------------------------------- phone

class PhoneError(Exception):
    def __init__(self, code, msg):
        super().__init__(msg)
        self.code = code
        self.msg = msg


def is_connection_error(e):
    try:
        from pymobiledevice3.exceptions import AfcException, ConnectionTerminatedError
        if isinstance(e, AfcException):
            return False
        if isinstance(e, ConnectionTerminatedError):
            return True
    except Exception:
        pass
    return isinstance(e, (ConnectionError, BrokenPipeError, EOFError, asyncio.IncompleteReadError)) or \
        "connection" in type(e).__name__.lower()


class Phone:
    def __init__(self, mock_dir=None):
        self.mock_dir = mock_dir
        self.lockdown = None
        self.afc = None
        self.info = {}
        self._connect_lock = asyncio.Lock()
        self._read_sem = asyncio.Semaphore(READ_CONCURRENCY)
        self._inflight = {}
        self.reset_index()

    def reset_index(self):
        self.folders = None
        self.folder_entries = {}
        self.items = {}

    async def close(self):
        afc, ld = self.afc, self.lockdown
        self.afc = self.lockdown = None
        self.info = {}
        self.reset_index()
        for closer in ((afc.aclose if afc else None), (ld.close if ld else None)):
            if closer:
                try:
                    await closer()
                except Exception:
                    pass

    # ---- connection

    async def status(self):
        if self.mock_dir:
            if not self.afc:
                self.afc = MockAfc(self.mock_dir)
                self.info = {"serial": "mock", "name": "模拟 iPhone（本地文件夹）", "model": "Mock", "ios": "-"}
            return {"state": "ready", **self.info}

        from pymobiledevice3 import usbmux
        try:
            devices = await usbmux.list_devices()
        except Exception as e:
            log.warning("usbmuxd: %s", e)
            return {"state": "error", "message": f"无法连接系统的 usbmuxd 服务：{e}"}
        usb = [d for d in devices if getattr(d, "connection_type", "USB") == "USB"]
        if not usb:
            if self.afc:
                log.info("device detached")
                await self.close()
            return {"state": "nodevice"}
        serial = usb[0].serial
        if self.afc and self.info.get("serial") == serial:
            return {"state": "ready", **self.info}

        async with self._connect_lock:
            if self.afc and self.info.get("serial") == serial:
                return {"state": "ready", **self.info}
            await self.close()
            from pymobiledevice3.lockdown import create_using_usbmux
            from pymobiledevice3.services.afc import AfcService
            from pymobiledevice3 import exceptions as ex
            t0 = time.perf_counter()
            try:
                ld = await create_using_usbmux(serial=serial, autopair=True, pair_timeout=0)
            except ex.PairingDialogResponsePendingError:
                return {"state": "pairing"}
            except ex.UserDeniedPairingError:
                return {"state": "denied"}
            except ex.PasswordRequiredError:
                return {"state": "locked"}
            except (ex.NotTrustedError, ex.PairingError) as e:
                log.info("pairing: %r", e)
                return {"state": "pairing"}
            except Exception as e:
                log.exception("lockdown failed")
                return {"state": "error", "message": f"{type(e).__name__}: {e}"}
            try:
                afc = AfcService(ld)
                await afc.__aenter__()
            except Exception as e:
                log.exception("afc failed")
                try:
                    await ld.close()
                except Exception:
                    pass
                name = type(e).__name__
                if "Password" in name or "Passcode" in name or "Locked" in name:
                    return {"state": "locked"}
                return {"state": "error", "message": f"{name}: {e}"}
            v = ld.all_values or {}
            model = None
            try:
                model = ld.display_name
            except Exception:
                pass
            self.lockdown, self.afc = ld, afc
            self.info = {"serial": serial, "name": v.get("DeviceName") or "iPhone",
                         "model": model or v.get("ProductType") or "", "ios": v.get("ProductVersion") or ""}
            log.info("connected %s (%s, iOS %s) in %.2fs", self.info["name"], self.info["model"],
                     self.info["ios"], time.perf_counter() - t0)
            return {"state": "ready", **self.info}

    def _need_afc(self):
        if not self.afc:
            raise PhoneError("device_lost", "iPhone 未连接")
        return self.afc

    # ---- listing (只列需要的那一页)

    async def _folders(self):
        if self.folders is None:
            afc = self._need_afc()
            names = [n for n in await afc.listdir(DCIM) if not n.startswith(".")]
            # 100APPLE、101APPLE… 或 202510__ 这类命名，按名字倒序基本就是新到旧
            names.sort(reverse=True)
            self.folders = [posixpath.join(DCIM, n) for n in names]
            log.info("DCIM folders: %s", names[:8])
        return self.folders

    async def _entries(self, folder):
        if folder not in self.folder_entries:
            afc = self._need_afc()
            try:
                names = await afc.listdir(folder)
            except Exception as e:
                if is_connection_error(e):
                    raise
                names = []
            groups = {}
            for n in names:
                if n.startswith("."):
                    continue
                stem, ext = posixpath.splitext(n)
                ext = ext.lower()
                if ext in PHOTO_EXT or ext in VIDEO_EXT:
                    groups.setdefault(stem, {})[ext] = n
            entries = []
            for stem, files in groups.items():
                photos = [e for e in files if e in PHOTO_EXT]
                videos = [files[e] for e in files if e in VIDEO_EXT]
                if photos:
                    photos.sort(key=lambda e: MAIN_PRIORITY.index(e) if e in MAIN_PRIORITY else 99)
                    main = files[photos[0]]
                    extra = [files[e] for e in photos[1:]]
                    # 同名的照片 + 视频 = 实况照片
                    entries.append({"main": main, "live": videos[0] if videos else None, "extra": extra})
                else:
                    for v in videos:
                        entries.append({"main": v, "live": None, "extra": []})
            entries.sort(key=lambda e: e["main"], reverse=True)
            self.folder_entries[folder] = entries
        return self.folder_entries[folder]

    async def _make_item(self, folder, e):
        afc = self._need_afc()
        main = posixpath.join(folder, e["main"])
        paths = [main] + ([posixpath.join(folder, e["live"])] if e["live"] else []) + \
                [posixpath.join(folder, x) for x in e["extra"]]
        stats = await asyncio.gather(*[afc.stat(p) for p in paths])
        files = []
        for p, st in zip(paths, stats):
            bt = st.get("st_birthtime") or st.get("st_mtime")
            files.append([p, int(st["st_size"]), bt.timestamp()])
        ext = posixpath.splitext(main)[1].lower()
        item = {
            "id": main,
            "name": e["main"],
            "ext": ext.lstrip(".").upper(),
            "kind": "video" if ext in VIDEO_EXT else "photo",
            "live": bool(e["live"]),
            "liveName": e["live"],
            "size": sum(f[1] for f in files),
            "mainSize": files[0][1],
            "fileCount": len(files),
            "t": int(files[0][2] * 1000),
        }
        self.items[main] = {**item, "files": files, "_ext": ext}
        return item

    async def list_page(self, cursor, limit):
        folders = await self._folders()
        fi, ii = (cursor or [0, 0])
        picked = []
        while fi < len(folders) and len(picked) < limit:
            ents = await self._entries(folders[fi])
            take = ents[ii: ii + (limit - len(picked))]
            picked.extend((folders[fi], e) for e in take)
            ii += len(take)
            if ii >= len(ents):
                fi, ii = fi + 1, 0
        t0 = time.perf_counter()
        items = await asyncio.gather(*[self._make_item(f, e) for f, e in picked])
        log.info("list page: %d items, stat %.2fs", len(items), time.perf_counter() - t0)
        next_cursor = None if fi >= len(folders) else [fi, ii]
        return items, next_cursor

    # ---- thumbnails / preview

    def _paths(self, item):
        key = hashlib.sha1(f"{self.info.get('serial')}|{item['id']}|{item['size']}".encode()).hexdigest()[:24]
        d = CACHE_DIR / "thumbs" / key[:2]
        d.mkdir(parents=True, exist_ok=True)
        return d / f"{key}.jpg", d / f"{key}_p.jpg", d / f"{key}.json"

    async def _read(self, path):
        afc = self._need_afc()
        async with self._read_sem:
            return await afc.get_file_contents(path)

    async def _once(self, key, factory):
        task = self._inflight.get(key)
        if task is None:
            task = asyncio.ensure_future(factory())
            self._inflight[key] = task
            task.add_done_callback(lambda _t: self._inflight.pop(key, None))
        return await asyncio.shield(task)

    def _item(self, item_id):
        item = self.items.get(item_id)
        if not item:
            raise PhoneError("unknown_item", "这张照片不在当前列表里，请刷新")
        return item

    async def thumb(self, item_id):
        item = self._item(item_id)
        tp, pp, mp = self._paths(item)
        if mp.exists():
            meta = json.loads(mp.read_text())
            if meta.get("noThumb") or tp.exists():
                return self._thumb_result(item_id, tp, meta, cached=True)
        meta = await self._once("t:" + str(mp), lambda: self._build_thumb(item, tp, pp, mp))
        return self._thumb_result(item_id, tp, meta, cached=False)

    def _thumb_result(self, item_id, tp, meta, cached):
        data = None if meta.get("noThumb") else base64.b64encode(tp.read_bytes()).decode()
        return {"id": item_id, "thumb": data, "cached": cached,
                **{k: meta.get(k) for k in ("taken", "w", "h", "noThumb")}}

    async def _build_thumb(self, item, tp, pp, mp):
        limit = VIDEO_THUMB_MAX_BYTES if item["kind"] == "video" else PHOTO_READ_MAX_BYTES
        if item["mainSize"] > limit:
            meta = {"noThumb": True, "error": "file too large for thumbnail"}
            mp.write_text(json.dumps(meta))
            return meta
        t0 = time.perf_counter()
        data = await self._read(item["id"])
        t1 = time.perf_counter()
        meta = await asyncio.get_running_loop().run_in_executor(
            POOL, build_thumb, data, item["_ext"], item["kind"], tp, pp, mp)
        log.info("thumb %s %.1fMB read %.2fs build %.2fs via %s", item["name"], len(data) / 1e6,
                 t1 - t0, time.perf_counter() - t1, meta.get("via", "-"))
        return meta

    async def preview(self, item_id):
        item = self._item(item_id)
        tp, pp, mp = self._paths(item)
        if not pp.exists():
            await self._once("p:" + str(pp), lambda: self._build_preview(item, pp))
        if not pp.exists():
            return {"id": item_id, "data": None}
        return {"id": item_id, "data": base64.b64encode(pp.read_bytes()).decode()}

    async def _build_preview(self, item, pp):
        limit = VIDEO_THUMB_MAX_BYTES if item["kind"] == "video" else PHOTO_READ_MAX_BYTES
        if item["mainSize"] > limit:
            return None
        data = await self._read(item["id"])
        try:
            return await asyncio.get_running_loop().run_in_executor(
                POOL, build_preview, data, item["_ext"], item["kind"], pp)
        except Exception as e:
            log.warning("preview failed %s: %s", item["name"], e)
            return None

    # ---- export

    async def export(self, ids, progress):
        afc = self._need_afc()
        files = []
        for i in ids:
            item = self.items.get(i)
            if not item:
                raise PhoneError("unknown_item", f"找不到 {posixpath.basename(i)}，请刷新后重选")
            files.extend(item["files"])
        dest = DOWNLOADS / f"iPhone {datetime.now():%Y-%m-%d}"
        dest.mkdir(parents=True, exist_ok=True)
        total = sum(f[1] for f in files) or 1
        done = 0
        written, skipped = [], 0
        last_emit = 0.0
        for idx, (src, size, t) in enumerate(files, 1):
            name = posixpath.basename(src)
            out = dest / name
            if out.exists() and out.stat().st_size == size:
                skipped += 1
                done += size
                continue
            n = 1
            while out.exists():
                out = dest / f"{Path(name).stem} ({n}){Path(name).suffix}"
                n += 1
            tmp = out.with_name(out.name + ".part")
            handle = await afc.fopen(src)
            try:
                with open(tmp, "wb") as f:
                    remaining = size
                    while remaining > 0:
                        chunk = await afc.fread(handle, min(CHUNK, remaining))
                        if not chunk:
                            break
                        f.write(chunk)
                        remaining -= len(chunk)
                        done += len(chunk)
                        now = time.monotonic()
                        if now - last_emit > 0.15:
                            last_emit = now
                            progress({"index": idx, "count": len(files), "file": name, "done": done, "total": total})
            finally:
                await afc.fclose(handle)
            os.replace(tmp, out)
            os.utime(out, (t, t))
            written.append(str(out))
        progress({"index": len(files), "count": len(files), "file": "", "done": total, "total": total})
        log.info("exported %d items, %d files written, %d skipped -> %s", len(ids), len(written), skipped, dest)
        return {"dir": str(dest), "files": written, "skipped": skipped, "count": len(ids)}


# ---------------------------------------------------------------- dispatcher

async def handle(phone, msg):
    rid = msg.get("rid")
    cmd = msg.get("cmd")
    try:
        if cmd == "hello":
            res = {"version": VERSION}
        elif cmd == "status":
            res = await phone.status()
        elif cmd == "list":
            items, cursor = await phone.list_page(msg.get("cursor"), max(1, min(int(msg.get("limit", 40)), 200)))
            res = {"items": items, "cursor": cursor}
        elif cmd == "refresh":
            phone.reset_index()
            res = {}
        elif cmd == "thumb":
            res = await phone.thumb(msg["id"])
        elif cmd == "preview":
            res = await phone.preview(msg["id"])
        elif cmd == "export":
            res = await phone.export(list(msg.get("ids") or []),
                                     lambda p: send({"event": "progress", "rid": rid, **p}))
        elif cmd == "reveal":
            path = Path(msg.get("path", "")).expanduser()
            if str(path).startswith(str(Path.home())) and path.exists():
                subprocess.Popen(["open", str(path)])
            res = {}
        else:
            raise PhoneError("bad_cmd", f"未知命令 {cmd}")
        send({"rid": rid, "ok": True, "result": res})
    except PhoneError as e:
        send({"rid": rid, "ok": False, "code": e.code, "error": e.msg})
    except asyncio.CancelledError:
        raise
    except Exception as e:
        code = "error"
        if is_connection_error(e):
            log.warning("connection lost during %s: %r", cmd, e)
            await phone.close()
            code = "device_lost"
        else:
            log.exception("command %s failed", cmd)
        send({"rid": rid, "ok": False, "code": code, "error": f"{type(e).__name__}: {e}"})


async def serve(mock):
    loop = asyncio.get_running_loop()
    queue = asyncio.Queue()
    threading.Thread(target=stdin_reader, args=(loop, queue), daemon=True).start()
    phone = Phone(mock)
    tasks = set()
    log.info("helper %s started (pid %d)", VERSION, os.getpid())
    while True:
        msg = await queue.get()
        if msg is None:
            break
        t = asyncio.create_task(handle(phone, msg))
        tasks.add(t)
        t.add_done_callback(tasks.discard)
    log.info("chrome disconnected, exiting")
    if tasks:
        _done, pending = await asyncio.wait(tasks, timeout=2)
        for t in pending:
            t.cancel()
    await phone.close()


# ---------------------------------------------------------------- self test

async def selftest(mock):
    phone = Phone(mock)
    print("正在查找 iPhone…")
    st = {}
    for _ in range(60):
        st = await phone.status()
        if st["state"] == "ready":
            break
        hint = {"nodevice": "没检测到 iPhone，请用数据线连接",
                "pairing": "请在 iPhone 上点「信任」并输入密码",
                "locked": "请解锁 iPhone",
                "denied": "iPhone 上点了「不信任」，请拔线重插"}.get(st["state"], st.get("message", st["state"]))
        print("  " + hint)
        await asyncio.sleep(2)
    if st.get("state") != "ready":
        print("超时，退出。")
        return 1
    print(f"已连接：{st['name']}（{st['model']}，iOS {st['ios']}）")

    t0 = time.perf_counter()
    folders = await phone._folders()
    t1 = time.perf_counter()
    print(f"DCIM 里有 {len(folders)} 个文件夹，列目录用时 {t1 - t0:.2f}s，最新的几个：{[posixpath.basename(f) for f in folders[:4]]}")
    items, cursor = await phone.list_page(None, 20)
    t2 = time.perf_counter()
    print(f"列出最新 {len(items)} 项（含逐个读取大小和时间）用时 {t2 - t1:.2f}s")
    for it in items[:6]:
        print(f"  {it['name']:<16} {datetime.fromtimestamp(it['t'] / 1000):%m-%d %H:%M}  "
              f"{it['size'] / 1e6:5.1f} MB{'  实况' if it['live'] else ''}")
    t3 = time.perf_counter()
    results = await asyncio.gather(*[phone.thumb(it["id"]) for it in items], return_exceptions=True)
    t4 = time.perf_counter()
    ok = sum(1 for r in results if isinstance(r, dict) and r.get("thumb"))
    print(f"生成 {ok}/{len(items)} 张缩略图用时 {t4 - t3:.2f}s（第二次打开会走缓存）")
    print(f"从插线到首屏 20 张，估计约 {t4 - t0:.1f}s（不含助手启动和配对）")
    vias = {}
    for it in items:
        mp = phone._paths(phone.items[it["id"]])[2]
        if mp.exists():
            v = json.loads(mp.read_text()).get("via", "none")
            vias[v] = vias.get(v, 0) + 1
    print(f"缩略图来源统计：{vias}（embedded = 用了 HEIC 内嵌缩略图，最快）")
    if items:
        t5 = time.perf_counter()
        pv = await phone.preview(items[0]["id"])
        print(f"放大预览第一张用时 {time.perf_counter() - t5:.2f}s，大小 {len(pv['data'] or '') * 3 // 4 // 1024} KB")
    errs = [r for r in results if isinstance(r, Exception)]
    if errs:
        print("有错误：", errs[:3])
    print(f"缓存目录：{CACHE_DIR}\n日志：{LOG_FILE}")
    await phone.close()
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--mock", help="用本地文件夹模拟手机（需含 DCIM 子目录）")
    args, _unknown = ap.parse_known_args()   # Chrome 会附带扩展来源参数，忽略即可
    mock = args.mock or os.environ.get("IPHONE_PHOTOS_MOCK_DIR")
    mock_file = Path.home() / "Library" / "Application Support" / APP / "mock_dir"
    if not mock and mock_file.exists():   # 开发用：写入一个本地文件夹路径，Chrome 启动的助手就会用模拟手机
        mock = mock_file.read_text().strip() or None
    setup_logging(console=args.selftest)
    if args.selftest:
        sys.stdout = sys.__stdout__
        code = asyncio.run(selftest(mock))
        os._exit(code)
    try:
        asyncio.run(serve(mock))
    except Exception:
        log.exception("fatal")
    os._exit(0)


if __name__ == "__main__":
    main()
