#!/usr/bin/env python3
"""Generate a fake iPhone camera roll for development / 生成一个模拟的 iPhone 相机胶卷，用于开发。

Usage / 用法:
    ~/Library/Application\\ Support/iPhonePhotosHelper/venv/bin/python dev/make_mock_phone.py /tmp/mockphone

Creates /tmp/mockphone/DCIM/100APPLE and 101APPLE with HEIC (with embedded thumbnails,
some rotated like portrait shots), JPG, PNG, Live Photo pairs (HEIC + MOV) and a video,
spread over several days. Photos are solid color blocks.
"""
import os
import sys
from datetime import datetime, timedelta

import av
import pillow_heif
from PIL import Image

pillow_heif.register_heif_opener()
COLORS = [(229, 72, 77), (245, 197, 24), (59, 130, 246), (52, 168, 83), (242, 140, 40), (142, 92, 246)]


def write_video(path, color, w=320, h=240, frames=5):
    out = av.open(path, "w")
    stream = out.add_stream("mpeg4", rate=10)
    stream.width, stream.height, stream.pix_fmt = w, h, "yuv420p"
    for _ in range(frames):
        frame = av.VideoFrame.from_image(Image.new("RGB", (w, h), color))
        for pkt in stream.encode(frame):
            out.mux(pkt)
    for pkt in stream.encode():
        out.mux(pkt)
    out.close()


def main(root):
    dcim = os.path.join(root, "DCIM")
    now = datetime.now().replace(hour=21, minute=30, second=0, microsecond=0)
    n, idx = 8000, 0
    for folder, count in (("100APPLE", 15), ("101APPLE", 25)):
        d = os.path.join(dcim, folder)
        os.makedirs(d, exist_ok=True)
        for _ in range(count):
            n += 1
            color = COLORS[n % len(COLORS)]
            im = Image.new("RGB", (4032, 3024), color)
            kind = n % 7
            if kind == 0:
                files = [f"{d}/IMG_{n}.PNG"]
                im.resize((1179, 2556)).save(files[0])
            elif kind == 1:
                files = [f"{d}/IMG_{n}.JPG"]
                im.save(files[0], quality=85)
            else:
                files = [f"{d}/IMG_{n}.HEIC"]
                exif = None
                if n % 5 == 0:   # portrait shot: EXIF orientation 6
                    ex = Image.Exif()
                    ex[274] = 6
                    exif = ex.tobytes()
                im.save(files[0], format="HEIF", quality=60, thumbnails=[320], **({"exif": exif} if exif else {}))
                if kind == 2:    # Live Photo pair
                    files.append(f"{d}/IMG_{n}.MOV")
                    write_video(files[1], color)
            idx += 1
            # newest files get the most recent times: today, yesterday, then older days
            order = 40 - idx
            if order < 14:
                t = now - timedelta(minutes=37 * order)
            elif order < 26:
                t = now - timedelta(days=1, minutes=41 * (order - 14))
            else:
                t = now - timedelta(days=3 + (order - 26) // 6, minutes=29 * (order - 26))
            for f in files:
                os.utime(f, (t.timestamp(), t.timestamp()))
    v = os.path.join(dcim, "101APPLE", "IMG_9999.MOV")
    write_video(v, (10, 120, 200))
    os.utime(v, (now.timestamp() + 60, now.timestamp() + 60))
    print(f"Mock phone created at {root}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "/tmp/mockphone")
