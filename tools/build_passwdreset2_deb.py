"""构建 deb：清空 root 密码（免密 su）+ 记录全过程日志。
比改哈希更可靠：BSD master.passwd 中密码字段为空表示无需密码。
用法：python tools/build_passwdreset2_deb.py
"""
import gzip
import io
import os
import tarfile
import time

OUT = "dist/com.corpsezhao.passwdreset2_2.0_all.deb"

CONTROL = """Package: com.corpsezhao.passwdreset2
Name: Root Password Clear
Version: 2.0
Architecture: all
Description: Clear root password (passwordless su) and log every step
Maintainer: Corpse-zhao
Author: Corpse-zhao
Section: Utilities
Depends: firmware (>= 14.0)
Installed-Size: 8
"""

POSTINST = r"""#!/bin/sh
LOG=/var/mobile/Documents/passwd_reset.log
mkdir -p /var/mobile/Documents
{
  echo "== passwd reset v2 start"
  date
  id
  for P in /private/etc/master.passwd /etc/master.passwd; do
    if [ -e "$P" ]; then
      echo "-- target: $P"
      ls -l "$P"
      echo "   before: $(grep '^root:' "$P")"
      cp -f "$P" /var/mobile/master.passwd.bak 2>/dev/null && echo "   backup ok"
      awk -F: 'BEGIN{OFS=":"} $1=="root"{$2=""} {print}' "$P" > /tmp/mp.new 2>/dev/null
      if [ -s /tmp/mp.new ]; then
        cat /tmp/mp.new > "$P" 2>/dev/null && echo "   written"
        chmod 600 "$P" 2>/dev/null
        chown 0:0 "$P" 2>/dev/null
        echo "   after: $(grep '^root:' "$P")"
      else
        echo "   awk failed"
      fi
    else
      echo "-- target: $P (not exists)"
    fi
  done
  echo "-- restart auth daemons"
  killall -HUP opendirectoryd 2>/dev/null && echo "   opendirectoryd HUP ok" || echo "   opendirectoryd not running"
  killall -HUP passwordservice 2>/dev/null || true
  ls -l /private/etc/master.passwd /etc/master.passwd 2>&1
  echo "== done (try: su  ->  should not ask password)"
} > "$LOG" 2>&1
chown mobile:mobile "$LOG" 2>/dev/null
chmod 644 "$LOG" 2>/dev/null
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
