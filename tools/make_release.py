#!/usr/bin/env python3
import hashlib
import os
import shutil
import sys
import zipfile


VERSION = "1.3.6"
LABEL = "通用版"
APK_BASENAME = f"手机端值班室-v{VERSION}-{LABEL}.apk"
ZIP_BASENAME = f"手机端值班室-v{VERSION}-{LABEL}.zip"
SHARE_APK_BASENAME = f"mobile-duty-room-v{VERSION}.apk"
SHARE_ZIP_BASENAME = f"mobile-duty-room-v{VERSION}-transfer.zip"


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def replace_copy(source, target):
    temporary = target + ".tmp"
    if os.path.exists(temporary):
        os.remove(temporary)
    shutil.copy2(source, temporary)
    os.replace(temporary, target)


def build_transfer_zip(source_apk, target_zip, archive_name):
    temporary = target_zip + ".tmp"
    if os.path.exists(temporary):
        os.remove(temporary)
    with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.write(source_apk, arcname=archive_name)
    with zipfile.ZipFile(temporary, "r") as archive:
        names = archive.namelist()
        if names != [archive_name]:
            raise SystemExit(f"unexpected ZIP entries: {names}")
        if any("\\" in name for name in names):
            raise SystemExit("ZIP entries must use forward slashes")
        if archive.testzip() is not None:
            raise SystemExit("ZIP integrity validation failed")
    os.replace(temporary, target_zip)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: make_release.py <project-root> <source-apk>")
    project_root = os.path.abspath(sys.argv[1])
    source_apk = os.path.abspath(sys.argv[2])
    share_dir = os.path.join(project_root, "apk-share")
    os.makedirs(share_dir, exist_ok=True)

    release_apk = os.path.join(project_root, APK_BASENAME)
    release_zip = os.path.join(project_root, ZIP_BASENAME)
    share_apk = os.path.join(share_dir, SHARE_APK_BASENAME)
    share_zip = os.path.join(share_dir, SHARE_ZIP_BASENAME)

    replace_copy(source_apk, release_apk)
    build_transfer_zip(release_apk, release_zip, APK_BASENAME)
    replace_copy(release_apk, share_apk)
    replace_copy(release_zip, share_zip)

    print(f"APK={release_apk}")
    print(f"APK_SHA256={sha256(release_apk)}")
    print(f"ZIP={release_zip}")
    print(f"ZIP_SHA256={sha256(release_zip)}")
    print(f"SHARE_APK={share_apk}")
    print(f"SHARE_ZIP={share_zip}")


if __name__ == "__main__":
    main()
