#!/usr/bin/env python3
"""Avoid the fragile NapCat get_msg lookup for inbound reply segments."""

from __future__ import annotations

import sys
from pathlib import Path


MARKER = "# zbs-astrbot-runtime-patch"


def find_adapter(venv: Path) -> Path:
    matches = sorted(
        venv.glob("lib/python*/site-packages/astrbot/core/platform/sources/aiocqhttp/aiocqhttp_platform_adapter.py")
    )
    if not matches:
        raise SystemExit(f"AstrBot OneBot adapter not found under {venv}")
    return matches[0]


def patch(path: Path) -> None:
    source = path.read_text(encoding="utf-8")
    if MARKER in source:
        return

    old_convert = "            abm = await self._convert_handle_message_event(event)\n"
    new_convert = (
        "            # zbs-astrbot-runtime-patch: do not query NapCat get_msg for replies\n"
        "            abm = await self._convert_handle_message_event(event, get_reply=False)\n"
    )
    if source.count(old_convert) != 1:
        raise SystemExit(f"AstrBot convert_message structure changed: {path}")
    source = source.replace(old_convert, new_convert, 1)

    source = MARKER + "\n" + source
    path.write_text(source, encoding="utf-8", newline="\n")


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_astrbot_runtime.py <astrbot-venv>")
    patch(find_adapter(Path(sys.argv[1])))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
