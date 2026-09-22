#!/usr/bin/env python3
import json
import re
import urllib.request


CONFIG_URLS = [
    "https://cdn-go.cn/qq-web/im.qq.com_new/latest/rainbow/linuxConfig.js",
    "https://im.qq.com/linuxqq/index.shtml",
]

REQUIRED_QQ_VERSION = "3.2.23-44343"
REQUIRED_QQ_BASE_VERSION = REQUIRED_QQ_VERSION.split("-", 1)[0]
PINNED_URLS = []


def fetch(url):
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "Mozilla/5.0", "Cache-Control": "no-cache"},
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.read().decode("utf-8", "replace")


def add(candidates, value, require_match=True):
    if not value:
        return
    value = value.replace("\\/", "/").strip()
    if value.startswith("//"):
        value = "https:" + value
    if require_match and REQUIRED_QQ_BASE_VERSION not in value:
        return
    if value.startswith("https://") and value not in candidates:
        candidates.append(value)


def from_config_js(text, candidates):
    match = re.search(
        r'"armDownloadUrl"\s*:\s*\{[^}]*?"deb"\s*:\s*"([^"]+)"',
        text,
    )
    if match:
        add(candidates, match.group(1))


def main():
    candidates = []
    for url in PINNED_URLS:
        add(candidates, url, require_match=False)

    for url in CONFIG_URLS:
        try:
            text = fetch(url)
        except Exception:
            continue
        from_config_js(text, candidates)

    for url in candidates:
        print(url)
    return 0 if candidates else 1


if __name__ == "__main__":
    raise SystemExit(main())
