"""构建 deb：把 root 密码重置为 alpine（iOS 经典 DES hash /smx7MYTQIi2M）。
无 Mac/Theos 也能打：纯 Python 手写 ar + tar.gz 结构。
用法：python tools/build_passwdreset_deb.py
"""
import gzip
import io
import os
import tarfile
import time

OUT = "dist/com.corpsezhao.passwdreset_1.0_all.deb"

CONTROL = """Package: com.corpsezhao.passwdreset
Name: Root Password Reset
Version: 1.0
Architecture: all
Description: Reset root password back to alpine (jailbreak rescue)
Maintainer: Corpse-zhao
Author: Corpse-zhao
Section: Utilities
Depends: firmware (>= 14.0)
Installed-Size: 8
"""

POSTINST = """#!/bin/sh
# 把 root 密码重置为 alpine 的经典 iOS DES hash
set -e
MP=/etc/master.passwd
if [ -f "$MP" ]; then
  cp -f "$MP" /var/mobile/master.passwd.bak 2>/dev/null || true
  awk -F: 'BEGIN{OFS=":"} $1=="root"{$2="/smx7MYTQIi2M"} {print}' "$MP" > /tmp/mp.new || true
  if [ -s /tmp/mp.new ]; then
    cat /tmp/mp.new > "$MP"
    chmod 600 "$MP"
    chown 0:0 "$MP" 2>/dev/null || true
  fi
fi
# 顺手打开 SSH 密码登录，避免以后再锁死
if [ -f /etc/ssh/sshd_config ]; then
  sed -i '' 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config 2>/dev/null || true
  sed -i '' 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null || true
fi
echo "root password -> alpine"
exit 0
"""


def tgz(entries):
    """entries: list of (name, content_bytes|None, mode)"""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w") as tar:
        for name, content, mode in entries:
            info = tarfile.TarInfo(name)
            info.mtime = int(time.time())
            info.mode = mode
            info.uid = 0
            info.gid = 0
            if content is None:
                info.type = tarfile.DIRTYPE
                info.size = 0
                tar.addfile(info)
            else:
                info.size = len(content)
                tar.addfile(info, io.BytesIO(content))
    return gzip.compress(raw.getvalue(), mtime=0)


def ar(entries):
    """entries: list of (name, bytes) -> ar archive"""
    out = bytearray(b"!<arch>\n")
    for name, data in entries:
        header = (
            f"{name:<16}{int(time.time()):<12}{0:<6}{0:<6}{'100644':<8}{len(data):<10}`\n"
        ).encode()
        out += header + data
        if len(data) % 2:
            out += b"\n"
    return bytes(out)


def main():
    os.makedirs("dist", exist_ok=True)
    control_tar = tgz([
        ("./control", CONTROL.encode(), 0o644),
        ("./postinst", POSTINST.encode(), 0o755),
    ])
    data_tar = tgz([("./", None, 0o755)])
    deb = ar([
        ("debian-binary", b"2.0\n"),
        ("control.tar.gz", control_tar),
        ("data.tar.gz", data_tar),
    ])
    with open(OUT, "wb") as f:
        f.write(deb)
    print("wrote", OUT, len(deb), "bytes")


if __name__ == "__main__":
    main()
