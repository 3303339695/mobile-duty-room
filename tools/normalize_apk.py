#!/usr/bin/env python3
import sys
import zipfile


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: normalize_apk.py <input.apk> <output.apk>")
    source, target = sys.argv[1], sys.argv[2]
    with zipfile.ZipFile(source, "r") as input_archive:
        with zipfile.ZipFile(target, "w") as output_archive:
            for info in input_archive.infolist():
                info.compress_type = (
                    zipfile.ZIP_STORED
                    if info.filename.replace("\\", "/") == "resources.arsc"
                    else zipfile.ZIP_DEFLATED
                )
                output_archive.writestr(info, input_archive.read(info.filename))


if __name__ == "__main__":
    main()
