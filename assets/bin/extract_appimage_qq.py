#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import subprocess
import sys


SQUASHFS_MAGIC = b"hsqs"
ELF_MACHINE_ARM64 = 183
READ_SIZE = 1024 * 1024


def read_at(path, offset, size):
    with open(path, "rb") as handle:
        handle.seek(offset)
        return handle.read(size)


def validate_elf_arm64(path):
    header = read_at(path, 0, 20)
    if len(header) < 20 or header[:4] != b"\x7fELF":
        raise RuntimeError("AppImage 不是有效的 ELF 文件")
    if header[4] != 2 or header[5] != 1:
        raise RuntimeError("AppImage 不是 64 位小端 ELF 文件")
    machine = int.from_bytes(header[18:20], "little")
    if machine != ELF_MACHINE_ARM64:
        raise RuntimeError(f"AppImage 架构不是 AArch64（ELF machine={machine}）")


def valid_squashfs_superblock(path, offset):
    header = read_at(path, offset, 32)
    if len(header) < 32 or header[:4] != SQUASHFS_MAGIC:
        return False
    block_size = int.from_bytes(header[12:16], "little")
    compression = int.from_bytes(header[20:22], "little")
    major = int.from_bytes(header[28:30], "little")
    minor = int.from_bytes(header[30:32], "little")
    return (
        major == 4
        and minor == 0
        and block_size in (4096, 8192, 16384, 32768, 65536, 131072, 262144, 524288, 1048576)
        and compression <= 6
    )


def find_squashfs_offset(path):
    absolute = 0
    overlap = b""
    with open(path, "rb") as handle:
        while True:
            block = handle.read(READ_SIZE)
            if not block:
                break
            data = overlap + block
            search_from = 0
            while True:
                index = data.find(SQUASHFS_MAGIC, search_from)
                if index < 0:
                    break
                candidate = absolute - len(overlap) + index
                if candidate > 0 and valid_squashfs_superblock(path, candidate):
                    return candidate
                search_from = index + 1
            overlap = data[-3:]
            absolute += len(block)
    raise RuntimeError("AppImage 中没有找到 SquashFS 文件系统")


def read_qq_version(output_dir):
    package_path = os.path.join(output_dir, "resources", "app", "package.json")
    try:
        with open(package_path, "r", encoding="utf-8-sig") as handle:
            package = json.load(handle)
    except Exception as exc:
        raise RuntimeError(f"无法读取 QQ package.json：{exc}") from exc
    version = str(package.get("version") or "").strip()
    if not version:
        raise RuntimeError("QQ package.json 中没有 version")
    return version


def extract(archive, output, expected_version):
    validate_elf_arm64(archive)
    offset = find_squashfs_offset(archive)
    output = os.path.abspath(output)
    if output in ("", os.path.sep):
        raise RuntimeError("输出目录无效")
    if os.path.exists(output):
        shutil.rmtree(output)
    os.makedirs(os.path.dirname(output), exist_ok=True)

    command = [
        "unsquashfs",
        "-no-progress",
        "-offset",
        str(offset),
        "-d",
        output,
        archive,
    ]
    try:
        subprocess.run(command, check=True)
    except FileNotFoundError as exc:
        raise RuntimeError("缺少 unsquashfs，请先安装 squashfs-tools") from exc
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"unsquashfs 解包失败，退出码 {exc.returncode}") from exc

    executable = os.path.join(output, "qq")
    if not os.path.isfile(executable):
        raise RuntimeError("AppImage 中没有找到 QQ 可执行文件")
    os.chmod(executable, 0o755)

    actual_version = read_qq_version(output)
    if expected_version and actual_version != expected_version:
        raise RuntimeError(
            f"QQ 内核版本不一致：期望 {expected_version}，实际 {actual_version}"
        )

    bundled_napcat = os.path.join(output, "napcat")
    if os.path.isdir(bundled_napcat):
        shutil.rmtree(bundled_napcat)

    print(
        f"[QQ 内核] AppImage 偏移 {offset}，已提取 Linux QQ {actual_version}（AArch64）",
        flush=True,
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--expected-version", default="")
    args = parser.parse_args()
    extract(args.archive, args.output, args.expected_version)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr, flush=True)
        raise SystemExit(1)
