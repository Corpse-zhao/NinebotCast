"""构建 deb：安装即用 root 权限在后台抓包 150 秒，输出 /var/mobile/Documents/cast.pcap。
绕开 su/密码问题——dpkg 的 postinst 本身就是 root。
用法：python tools/build_capture_deb.py
"""
import gzip
import io
import os
import tarfile
import time

OUT = "dist/com.corpsezhao.castcapture_1.0_all.deb"

CONTROL = """Package: com.corpsezhao.castcapture
Name: Cast Capture
Version: 1.0
Architecture: all
Description: Capture 150s of Wi-Fi traffic as root into /var/mobile/Documents/cast.pcap
Maintainer: Corpse-zhao
Author: Corpse-zhao
Section: Utilities
Depends: firmware (>= 14.0)
Installed-Size: 8
"""

POSTINST = r"""#!/bin/sh
set -e

DOC=/var/mobile/Documents
mkdir -p "$DOC"
rm -f "$DOC/cast.pcap" "$DOC/cast_capture.log"

TP=$(command -v tcpdump 2>/dev/null || true)
[ -z "$TP" ] && [ -x /usr/sbin/tcpdump ] && TP=/usr/sbin/tcpdump
[ -z "$TP" ] && [ -x /usr/bin/tcpdump ] && TP=/usr/bin/tcpdump
[ -z "$TP" ] && [ -x /var/jb/usr/bin/tcpdump ] && TP=/var/jb/usr/bin/tcpdump
[ -z "$TP" ] && [ -x /var/jb/usr/sbin/tcpdump ] && TP=/var/jb/usr/sbin/tcpdump

if [ -z "$TP" ]; then
  echo "tcpdump not found" > "$DOC/cast_capture.log"
  exit 0
fi

echo "using $TP" >> "$DOC/cast_capture.log"

# 150 秒后自动停止；-s 400 截断负载，文件控制在 ~10MB 内
nohup sh -c "$TP -i en0 -s 400 -w $DOC/cast.pcap >/dev/null 2>&1 & TPID=\$!; echo \"pid \$TPID\" >> $DOC/cast_capture.log; sleep 150; kill \$TPID 2>/dev/null; sleep 1; chown mobile:mobile $DOC/cast.pcap 2>/dev/null; chmod 644 $DOC/cast.pcap 2>/dev/null; ls -l $DOC/cast.pcap >> $DOC/cast_capture.log" >/dev/null 2>&1 &

exit 0
"""


def tgz(entries):
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
