"""用 GitHub REST API 推送整个目录（代理环境下比 git push 可靠）。

用法：
    GH_TOKEN=xxx python tools/push_repo.py Corpse-zhao/DataVision "提交说明"
"""

import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"
SKIP_DIRS = {
    ".git", "build", ".dart_tool", ".idea", "Pods", ".symlinks", ".gradle",
    "node_modules", ".vscode",
}
SKIP_EXT = {".iml", ".lock.tmp"}
SKIP_FILES = {".flutter-plugins", ".flutter-plugins-dependencies", ".packages"}


def req(method, path, token, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(API + path, data=data, method=method)
    r.add_header("Authorization", f"token {token}")
    r.add_header("Accept", "application/vnd.github+json")
    r.add_header("User-Agent", "datavision-push")
    if data:
        r.add_header("Content-Type", "application/json")
    # 强制不走系统代理
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(r, timeout=90) as resp:
            raw = resp.read().decode()
            return json.loads(raw) if raw.strip() else {}
    except urllib.error.HTTPError as e:
        print("HTTP", e.code, e.read().decode()[:400], file=sys.stderr)
        raise


def collect(root):
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and d != ".git"]
        for fn in filenames:
            if fn in SKIP_FILES:
                continue
            if os.path.splitext(fn)[1] in SKIP_EXT:
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root).replace("\\", "/")
            if rel.startswith(("research/", "test/preview/shots/")):
                continue
            out.append((rel, full))
    return out


def main():
    repo = sys.argv[1]
    message = sys.argv[2] if len(sys.argv) > 2 else "update"
    branch = "main"
    root = os.getcwd()
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        sys.exit("need GH_TOKEN")

    files = collect(root)
    print(f"{len(files)} files")

    # 空仓库不能直接建 blob（409 Git Repository is empty），先落一个初始提交把 git 库撑起来
    parent = None
    try:
        ref = req("GET", f"/repos/{repo}/git/ref/heads/{branch}", token)
        parent = ref["object"]["sha"]
    except urllib.error.HTTPError:
        parent = None
    if parent is None:
        req("PUT", f"/repos/{repo}/contents/.init", token, {
            "message": "chore: init",
            "content": base64.b64encode(b"init\n").decode(),
        })
        ref = req("GET", f"/repos/{repo}/git/ref/heads/{branch}", token)
        parent = ref["object"]["sha"]

    tree = []
    for rel, full in files:
        with open(full, "rb") as f:
            content = f.read()
        blob = req("POST", f"/repos/{repo}/git/blobs", token, {
            "content": base64.b64encode(content).decode(),
            "encoding": "base64",
        })
        tree.append({"path": rel, "mode": "100755" if os.access(full, os.X_OK) and not rel.endswith(('.dart', '.yaml', '.md', '.png', '.jpg', '.jks', '.kts', '.xml', '.plist')) else "100644",
                     "type": "blob", "sha": blob["sha"]})
        print("  blob", rel)

    new_tree = req("POST", f"/repos/{repo}/git/trees", token, {"tree": tree})
    commit_body = {"message": message, "tree": new_tree["sha"]}
    if parent:
        commit_body["parents"] = [parent]
    commit = req("POST", f"/repos/{repo}/git/commits", token, commit_body)
    print("commit", commit["sha"])

    if parent:
        req("PATCH", f"/repos/{repo}/git/refs/heads/{branch}", token, {"sha": commit["sha"], "force": True})
    else:
        req("POST", f"/repos/{repo}/git/refs", token, {"ref": f"refs/heads/{branch}", "sha": commit["sha"]})
    print("pushed to", repo, branch)


if __name__ == "__main__":
    main()
