#!/usr/bin/env python3
"""Talk to the helper the way Chrome does and check every command / 像 Chrome 一样和读取助手对话，逐条检查命令。

Usage / 用法:
    python3 dev/protocol_test.py <helper binary>                     # no phone: hello + status only / 不插手机：只测握手和状态
    python3 dev/protocol_test.py <helper binary> --mock <folder>     # full run on a mock phone / 用模拟手机测全部命令

Run it with HOME pointing at a temporary folder so exports and caches stay out of your real home:
用临时 HOME 运行，导出和缓存都不会进你真正的用户目录：
    HOME=$(mktemp -d) python3 dev/protocol_test.py helper/build/iPhonePhotosHelper.app/Contents/MacOS/iphone-photos-helper --mock /tmp/mockphone
"""
import base64
import json
import os
import struct
import subprocess
import sys
import threading
import time

ORIGIN = "chrome-extension://endldjnpicempoibdmlndkiinmmekggn/"


class Host:
    def __init__(self, binary, mock=None):
        env = dict(os.environ)
        env.pop("IPHONE_PHOTOS_MOCK_DIR", None)
        if mock:
            env["IPHONE_PHOTOS_MOCK_DIR"] = mock
        self.p = subprocess.Popen([binary, ORIGIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
        self.rid = 0
        self.replies, self.events = {}, []
        self.cv = threading.Condition()
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        while True:
            head = self.p.stdout.read(4)
            if len(head) < 4:
                return
            msg = json.loads(self.p.stdout.read(struct.unpack("<I", head)[0]))
            with self.cv:
                if msg.get("event"):
                    self.events.append(msg)
                else:
                    self.replies[msg["rid"]] = msg
                self.cv.notify_all()

    def call(self, cmd, timeout=60, **args):
        self.rid += 1
        rid = self.rid
        body = json.dumps({"rid": rid, "cmd": cmd, **args}).encode()
        self.p.stdin.write(struct.pack("<I", len(body)) + body)
        self.p.stdin.flush()
        with self.cv:
            if not self.cv.wait_for(lambda: rid in self.replies, timeout):
                raise TimeoutError(cmd)
            return self.replies.pop(rid)

    def close(self):
        self.p.stdin.close()
        return self.p.wait(timeout=10)


results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}{'  ' + detail if detail else ''}")


def main():
    binary = sys.argv[1]
    mock = sys.argv[sys.argv.index("--mock") + 1] if "--mock" in sys.argv else None
    h = Host(binary, mock)
    r = h.call("hello")
    check("hello", r["ok"] and r["result"]["version"].startswith("0."), r["result"].get("version", ""))
    t0 = time.time()
    r = h.call("status")
    state = r["result"].get("state")
    check("status", r["ok"] and state == ("ready" if mock else "nodevice"), f"{state} in {time.time() - t0:.1f}s")
    r = h.call("bogus")
    check("unknown command -> bad_cmd", not r["ok"] and r["code"] == "bad_cmd")
    if not mock:
        r = h.call("list", cursor=None, limit=30)
        check("list without phone -> device_lost", not r["ok"] and r["code"] == "device_lost", r.get("error", ""))
        check("exits when stdin closes", h.close() == 0)
        return

    seen, cursor, pages = [], None, 0
    while True:
        r = h.call("list", cursor=cursor, limit=30 if cursor is None else 60)
        if not r["ok"]:
            check("list", False, r.get("error"))
            break
        seen += r["result"]["items"]
        cursor, pages = r["result"]["cursor"], pages + 1
        if cursor is None:
            break
    times = [i["t"] for i in seen]
    check("list pages newest first", pages >= 1 and times == sorted(times, reverse=True), f"{len(seen)} items in {pages} pages")
    check("ids unique", len({i["id"] for i in seen}) == len(seen))
    live = [i for i in seen if i["live"]]
    check("live photos paired", bool(live) and all(i["fileCount"] >= 2 and i["liveName"].upper().endswith(".MOV") for i in live), f"{len(live)} live")
    keys = {"id", "name", "ext", "kind", "live", "liveName", "size", "mainSize", "fileCount", "t"}
    check("item fields", all(keys <= set(i) for i in seen))

    by_ext = {}
    for i in seen:
        by_ext.setdefault((i["ext"], i["kind"]), i)
    for (ext, kind), it in sorted(by_ext.items()):
        r = h.call("thumb", id=it["id"])
        ok = r["ok"] and r["result"].get("thumb")
        data = base64.b64decode(r["result"]["thumb"]) if ok else b""
        check(f"thumb {ext}/{kind}", ok and data[:2] == b"\xff\xd8", f"{len(data)} bytes, {r['result'].get('w')}x{r['result'].get('h')}, taken {r['result'].get('taken')}")
    r = h.call("thumb", id=seen[0]["id"])
    check("thumb second time is cached", r["ok"] and r["result"]["cached"])

    for (ext, kind), it in sorted(by_ext.items()):
        r = h.call("preview", id=it["id"])
        data = base64.b64decode(r["result"]["data"]) if r["ok"] and r["result"].get("data") else b""
        check(f"preview {ext}/{kind}", data[:2] == b"\xff\xd8" and len(data) < 700_000, f"{len(data)} bytes")

    r = h.call("thumb", id="/DCIM/nope.JPG")
    check("unknown id -> unknown_item", not r["ok"] and r["code"] == "unknown_item")

    pick = [live[0]["id"]] + [i["id"] for i in seen if not i["live"]][:2]
    r = h.call("export", ids=pick, timeout=120)
    ok = r["ok"]
    res = r["result"] if ok else {}
    expect = sum(i["fileCount"] for i in seen if i["id"] in pick)
    check("export", ok and len(res["files"]) == expect and res["dir"].startswith(os.environ["HOME"]), f"{len(res.get('files', []))} files -> {res.get('dir')}")
    if ok:
        sizes = {os.path.basename(f): os.path.getsize(f) for f in res["files"]}
        want = {}
        for i in seen:
            if i["id"] in pick:
                want[i["name"]] = i["mainSize"]
        check("exported originals byte-exact size", all(sizes.get(n) == s for n, s in want.items()))
        check("export progress events", any(e["event"] == "progress" for e in h.events), f"{len(h.events)} events")
    r = h.call("export", ids=pick, timeout=120)
    check("export again skips existing", r["ok"] and r["result"]["skipped"] == expect and not r["result"]["files"])
    r = h.call("refresh")
    check("refresh", r["ok"])
    r = h.call("thumb", id=seen[0]["id"])
    check("after refresh old ids need a new list", not r["ok"] and r["code"] == "unknown_item")
    check("exits when stdin closes", h.close() == 0)


if __name__ == "__main__":
    main()
    print(f"\n{sum(results)}/{len(results)} passed")
    sys.exit(0 if all(results) else 1)
