"""构建 deb：安装即以 root 生成诊断报告 /var/mobile/Documents/diag.txt
用于排查：postinst 是否执行、tcpdump 路径、/dev/bpf 权限、root 密码哈希格式。
用法：python tools/build_diag_deb.py
"""
import gzip
import io
import os
import tarfile
import time

OUT = "dist/com.corpsezhao.castdiag_1.0_all.deb"

CONTROL = """Package: com.corpsezhao.castdiag
Name: Cast Diag
Version: 1.0
Architecture: all
Description: Write environment diagnostics to /var/mobile/Documents/diag.txt
Maintainer: Corpse-zhao
Author: Corpse-zhao
Section: Utilities
Depends: firmware (>= 14.0)
Installed-Size: 8
"""

POSTINST = r"""#!/bin/sh
D=/var/mobile/Documents/diag.txt
mkdir -p /var/mobile/Documents
{
  echo "== diag start"
  date
  echo "== whoami / id"
  id
  echo "== uname"
  uname -a
  echo "== tcpdump candidates"
  command -v tcpdump 2>&1
  ls -l /usr/bin/tcpdump /usr/sbin/tcpdump /var/jb/usr/bin/tcpdump /var/jb/usr/sbin/tcpdump 2>&1
  echo "== bpf devices"
  ls -l /dev/bpf* 2>&1
  echo "== root entry (hash only)"
  grep '^root:' /etc/master.passwd 2>&1
  echo "== mobile entry"
  grep '^mobile:' /etc/master.passwd 2>&1
  echo "== etc perms"
  ls -l /etc/master.passwd 2>&1
  echo "== ssh"
  ls -l /etc/ssh 2>&1 | head -5
  echo "== our packages"
  dpkg -l 2>/dev/null | grep -i corpsezhao
  echo "== documents"
  ls -l /var/mobile/Documents 2>&1 | head -20
  echo "== diag end"
} > "$D" 2>&1
chown mobile:mobile "$D" 2>/dev/null
chmod 644 "$D" 2>/dev/null
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
