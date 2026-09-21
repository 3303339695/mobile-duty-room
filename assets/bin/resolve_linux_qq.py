#!/usr/bin/env python3
import json
import re
import urllib.request


CONFIG_URLS = [
    "https://cdn-go.cn/qq-web/im.qq.com_new/latest/rainbow/linuxConfig.js",
    "https://im.qq.com/linuxqq/index.shtml",
]

RELEASE_URLS = [
    "https://nclatest.znin.net/get_qq_ver",
    "https://raw.githubusercontent.com/NapNeko/NapCatQQ/main/packages/napcat-shell-loader/qqnt.json",
]


def fetch(url):
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "Mozilla/5.0", "Cache-Control": "no-cache"},
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.read().decode("utf-8", "replace")


def add(candidates, value):
    if not value:
        return
    value = value.replace("\\/", "/").strip()
    if value.startswith("//"):
        value = "https:" + value
    if value.startswith("https://") and value not in candidates:
        candidates.append(value)


def from_config_js(text, candidates):
    match = re.search(
        r'"armDownloadUrl"\s*:\s*\{[^}]*?"deb"\s*:\s*"([^"]+)"',
        text,
    )
    if match:
        add(candidates, match.group(1))


def from_release_json(text, candidates):
    try:
        payload = json.loads(text)
    except Exception:
        return
    version = payload.get("linuxVersion")
    build_hash = payload.get("linuxVerHash")
    if not version or not build_hash:
        return
    add(
        candidates,
        "https://dldir1.qq.com/qqfile/qq/QQNT/"
        f"{build_hash}/linuxqq_{version}_arm64.deb",
    )


def main():
    candidates = []
    for url in CONFIG_URLS:
        try:
            text = fetch(url)
        except Exception:
            continue
        from_config_js(text, candidates)

    for url in RELEASE_URLS:
        try:
            text = fetch(url)
        except Exception:
            continue
        from_release_json(text, candidates)

    # 官方离线恢复源：NapCat 社区验证过的 Linux QQ 3.2.18 ARM64。
    add(
        candidates,
        "https://dldir1v6.qq.com/qqfile/qq/QQNT/"
        "a5fab4ff/linuxqq_3.2.18-36580_arm64.deb",
    )
    add(
        candidates,
        "https://dldir1.qq.com/qqfile/qq/QQNT/"
        "a5fab4ff/linuxqq_3.2.18-36580_arm64.deb",
    )

    for url in candidates:
        print(url)
    return 0 if candidates else 1


if __name__ == "__main__":
    raise SystemExit(main())
