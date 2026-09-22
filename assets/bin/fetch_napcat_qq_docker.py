#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import posixpath
import shutil
import sys
import tarfile
import urllib.request


DEFAULT_REPOSITORY = "smanx/docker-qq"
DEFAULT_TAG = "3.2.23-44343"
DEFAULT_MANIFEST_DIGEST = (
    "sha256:f410a57799769f9069a4eb100f941e89c369bbc01044cfbf7efb877e9ba9139b"
)
DEFAULT_LAYER_DIGEST = (
    "sha256:383e8849887158afc622ae40168437dbbac6135ead7d34fc61c9f73f50e271c1"
)
REGISTRY = "https://registry-1.docker.io/v2"
INDEX_ACCEPT = (
    "application/vnd.oci.image.index.v1+json, "
    "application/vnd.docker.distribution.manifest.list.v2+json"
)
MANIFEST_ACCEPT = (
    "application/vnd.oci.image.manifest.v1+json, "
    "application/vnd.docker.distribution.manifest.v2+json"
)


def request(url, token="", accept="application/json"):
    headers = {"User-Agent": "Zhibanshi/1.2"}
    if token:
        headers["Authorization"] = "Bearer " + token
    if accept:
        headers["Accept"] = accept
    return urllib.request.Request(url, headers=headers)


def registry_token(repository):
    scope = f"repository:{repository}:pull"
    url = (
        "https://auth.docker.io/token"
        f"?service=registry.docker.io&scope={scope}"
    )
    with urllib.request.urlopen(request(url), timeout=30) as response:
        return json.load(response)["token"]


def fetch_manifest(repository, reference, token, accept):
    url = f"{REGISTRY}/{repository}/manifests/{reference}"
    with urllib.request.urlopen(request(url, token, accept), timeout=30) as response:
        return json.load(response)


def resolve_arm64_manifest(repository, tag, token, manifest_digest=""):
    if manifest_digest:
        document = fetch_manifest(
            repository, manifest_digest, token, MANIFEST_ACCEPT
        )
        if not document.get("layers"):
            raise RuntimeError("固定镜像摘要不是有效的 arm64 镜像清单")
        return document

    document = fetch_manifest(repository, tag, token, INDEX_ACCEPT)
    manifests = document.get("manifests")
    if not manifests:
        return document
    for item in manifests:
        platform = item.get("platform") or {}
        if platform.get("os") == "linux" and platform.get("architecture") == "arm64":
            return fetch_manifest(
                repository, item["digest"], token, MANIFEST_ACCEPT
            )
    raise RuntimeError("镜像中没有 linux/arm64 版本")


def choose_qq_layer(manifest, layer_digest=""):
    layers = manifest.get("layers") or []
    if not layers:
        raise RuntimeError("镜像清单中没有层文件")
    if layer_digest:
        for layer in layers:
            if layer.get("digest") == layer_digest:
                return layer
        raise RuntimeError("固定镜像清单中没有指定的 QQ 内核层")
    # 旧版 NapCat 镜像把 QQ 内核放在镜像最大的 tar 层中。
    return max(layers, key=lambda item: int(item.get("size") or 0))


def download_layer(repository, layer, target, token):
    digest = layer["digest"]
    expected_size = int(layer.get("size") or 0)
    url = f"{REGISTRY}/{repository}/blobs/{digest}"
    temporary = target + ".part"
    print(f"[QQ 内核] 下载镜像层：{digest}", flush=True)
    with urllib.request.urlopen(request(url, token, None), timeout=120) as response:
        total = int(response.headers.get("Content-Length") or expected_size or 0)
        written = 0
        digest_state = hashlib.sha256()
        step = max(1, total // 20) if total else 0
        next_report = step
        with open(temporary, "wb") as output:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                output.write(chunk)
                digest_state.update(chunk)
                written += len(chunk)
                if step and written >= next_report:
                    percent = min(100, written * 100 // total)
                    print(f"[QQ 内核] 已下载 {percent}%", flush=True)
                    next_report += step
    if expected_size and os.path.getsize(temporary) != expected_size:
        os.remove(temporary)
        raise RuntimeError("镜像层下载大小不一致")
    expected_digest = digest.split(":", 1)[-1]
    if digest_state.hexdigest() != expected_digest:
        os.remove(temporary)
        raise RuntimeError("镜像层校验值不一致")
    os.replace(temporary, target)


def digest_matches(path, digest):
    algorithm, expected = digest.split(":", 1)
    if algorithm != "sha256":
        raise RuntimeError("镜像层校验算法不受支持")
    state = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            state.update(chunk)
    return state.hexdigest() == expected


def selected_members(archive):
    members = []
    for member in archive:
        name = member.name.replace("\\", "/")
        while name.startswith("./"):
            name = name[2:]
        name = name.lstrip("/")
        normalized = posixpath.normpath(name)
        if normalized == "opt/QQ" or normalized.startswith("opt/QQ/"):
            member.name = normalized
            members.append(member)
    return members


def extract_qq(layer_path, output_dir):
    output_dir = os.path.abspath(output_dir)
    if output_dir == os.path.sep:
        raise RuntimeError("输出目录无效")
    if os.path.exists(output_dir):
        shutil.rmtree(output_dir)
    os.makedirs(output_dir, exist_ok=True)
    with tarfile.open(layer_path, "r:gz") as archive:
        members = selected_members(archive)
        if not any(member.name == "opt/QQ/qq" for member in members):
            raise RuntimeError("镜像层中没有找到 QQ 运行内核")
        try:
            archive.extractall(output_dir, members=members, filter="data")
        except TypeError:
            # Older Debian Python releases do not expose extraction filters.
            archive.extractall(output_dir, members=members)
    executable = os.path.join(output_dir, "opt", "QQ", "qq")
    if not os.path.isfile(executable):
        raise RuntimeError("QQ 运行内核提取不完整")
    os.chmod(executable, 0o755)
    return executable


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", default=DEFAULT_REPOSITORY)
    parser.add_argument("--tag", default=DEFAULT_TAG)
    parser.add_argument("--manifest-digest", default="")
    parser.add_argument("--layer-digest", default="")
    parser.add_argument("--output", required=True)
    parser.add_argument("--cache", required=True)
    args = parser.parse_args()

    os.makedirs(args.cache, exist_ok=True)
    manifest_digest = args.manifest_digest
    if (
        not manifest_digest
        and args.repository == DEFAULT_REPOSITORY
        and args.tag == DEFAULT_TAG
    ):
        manifest_digest = DEFAULT_MANIFEST_DIGEST
    layer_digest = args.layer_digest
    if (
        not layer_digest
        and args.repository == DEFAULT_REPOSITORY
        and args.tag == DEFAULT_TAG
    ):
        layer_digest = DEFAULT_LAYER_DIGEST
    token = registry_token(args.repository)
    manifest = resolve_arm64_manifest(
        args.repository, args.tag, token, manifest_digest
    )
    layer = choose_qq_layer(manifest, layer_digest)
    layer_path = os.path.join(
        args.cache,
        "napcat-qq-" + layer["digest"].split(":", 1)[-1] + ".tar.gz",
    )
    if os.path.isfile(layer_path) and digest_matches(layer_path, layer["digest"]):
        print("[QQ 内核] 复用已下载镜像层", flush=True)
    else:
        if os.path.exists(layer_path):
            os.remove(layer_path)
        download_layer(args.repository, layer, layer_path, token)

    try:
        executable = extract_qq(layer_path, args.output)
    finally:
        try:
            os.remove(layer_path)
        except OSError:
            pass
    print(f"[QQ 内核] 已准备：{executable}", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr, flush=True)
        raise SystemExit(1)
