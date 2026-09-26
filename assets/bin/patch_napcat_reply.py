#!/usr/bin/env python3
"""Patch NapCat's bundled OneBot reply lookup for newly sent messages."""

from __future__ import annotations

import argparse
from pathlib import Path


MARKER = "/* zbs-napcat-reply-retry */"
TARGET = "const c = async (u, l, d, f) => {"
REPLACEMENT = "const c0 = async (u, l, d, f) => {"
WRAPPER = """\
      /* zbs-napcat-reply-retry */
      const c = async (...args) => {
        for (let attempt = 0; attempt < 3; attempt++) {
          const result = await c0(...args);
          if (result) return result;
          if (attempt < 2) await new Promise((resolve) => setTimeout(resolve, 250));
        }
        return;
      };
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    args = parser.parse_args()

    path = args.path
    source = path.read_text(encoding="utf-8")
    if MARKER in source:
        return 0
    if source.count(TARGET) != 1:
        raise SystemExit(f"NapCat 引用查询代码结构不匹配：{path}")

    source = source.replace(TARGET, REPLACEMENT, 1)
    anchor = "      if (a && e.replyMsgTime && e.senderUidStr) {"
    if source.count(anchor) != 1:
        raise SystemExit(f"NapCat 引用查询插入位置不匹配：{path}")
    source = source.replace(anchor, WRAPPER + anchor, 1)
    path.write_text(source, encoding="utf-8", newline="\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
