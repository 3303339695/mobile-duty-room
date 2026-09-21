#!/usr/bin/env python3
import os
import sys
import time
import zipfile
import zlib


def build_package(source_apk, dex_file, temporary_apk):
    with zipfile.ZipFile(source_apk, "r") as source_archive:
        if "classes.dex" in source_archive.namelist():
            raise ValueError("source APK unexpectedly contains classes.dex")

        with zipfile.ZipFile(temporary_apk, "w", allowZip64=True) as output_archive:
            for info in source_archive.infolist():
                data = source_archive.read(info.filename)
                normalized_name = info.filename.replace("\\", "/")
                info.compress_type = (
                    zipfile.ZIP_STORED
                    if normalized_name == "resources.arsc"
                    else zipfile.ZIP_DEFLATED
                )
                output_archive.writestr(info, data)

            dex_info = zipfile.ZipInfo("classes.dex", date_time=(1980, 1, 1, 0, 0, 0))
            dex_info.compress_type = zipfile.ZIP_DEFLATED
            dex_info.external_attr = 0o100644 << 16
            with open(dex_file, "rb") as dex_stream:
                output_archive.writestr(dex_info, dex_stream.read())

    with zipfile.ZipFile(temporary_apk, "r") as verification_archive:
        if verification_archive.testzip() is not None:
            raise ValueError("packaged APK failed ZIP integrity validation")
        if "classes.dex" not in verification_archive.namelist():
            raise ValueError("packaged APK is missing classes.dex")


def main():
    if len(sys.argv) != 4:
        raise SystemExit(
            "usage: package_apk.py <unsigned.apk> <classes.dex> <output.apk>"
        )

    source_apk, dex_file, output_apk = sys.argv[1:]
    if not os.path.isfile(dex_file) or os.path.getsize(dex_file) == 0:
        raise SystemExit("classes.dex is missing or empty")

    temporary_apk = output_apk + ".tmp"
    last_error = None
    for attempt in range(20):
        try:
            if os.path.exists(temporary_apk):
                os.remove(temporary_apk)
            build_package(source_apk, dex_file, temporary_apk)
            break
        except (OSError, ValueError, zipfile.BadZipFile, zlib.error) as error:
            last_error = error
            if os.path.exists(temporary_apk):
                os.remove(temporary_apk)
            time.sleep(0.25)
    else:
        raise SystemExit(f"could not read stable source APK: {last_error}")

    os.replace(temporary_apk, output_apk)


if __name__ == "__main__":
    main()
