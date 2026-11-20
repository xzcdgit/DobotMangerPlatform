# -*- coding: utf-8 -*-
"""Parse DobotStudio Pro manual for communication-relevant content."""
from __future__ import annotations

import re
from pathlib import Path

from pypdf import PdfReader

PDF = Path(r"C:\Users\xiazhenc\Desktop\DobotStudio Pro 用户手册_V4.6.7_20260624_cn.pdf")
OUT = Path(r"D:\机器人可视化平台\_dobot_manual_extract")
OUT.mkdir(exist_ok=True)

KEYWORDS = [
    "Modbus", "modbus", "TCP", "寄存器", "保持寄存器", "线圈",
    "通讯", "通信", "从站", "主站", "Slave", "Master",
    "状态码", "状态", "EAP", "PLC", "工业以太网",
    "写寄存器", "读寄存器", "功能码", "Holding", "Input",
    "TCP/IP", "Socket", "Dashboard", "二次开发", "API",
    "脚本", "Lua", "全局变量", "IO", "DI", "DO",
]


def walk_outline(outlines, depth=0, lines=None):
    if lines is None:
        lines = []
    for o in outlines:
        if isinstance(o, list):
            walk_outline(o, depth + 1, lines)
        else:
            title = getattr(o, "title", str(o))
            lines.append(("  " * depth) + title)
    return lines


def main():
    reader = PdfReader(str(PDF))
    n = len(reader.pages)
    meta = OUT / "00_meta.txt"
    meta.write_text(f"pages={n}\nencrypted={reader.is_encrypted}\n", encoding="utf-8")
    print("pages", n)

    # TOC
    toc_lines = []
    try:
        if reader.outline:
            toc_lines = walk_outline(reader.outline)
    except Exception as e:
        toc_lines = [f"outline_err: {e}"]
    (OUT / "01_toc.txt").write_text("\n".join(toc_lines) or "NO_OUTLINE", encoding="utf-8")
    print("toc entries", len(toc_lines))

    # Front matter
    front = []
    for i in range(min(20, n)):
        t = reader.pages[i].extract_text() or ""
        front.append(f"\n===== PAGE {i+1} =====\n{t}")
    (OUT / "02_front.txt").write_text("\n".join(front), encoding="utf-8")

    # Keyword scan all pages (store hits)
    hits = []
    hit_pages = []
    for i, page in enumerate(reader.pages):
        t = page.extract_text() or ""
        found = [k for k in KEYWORDS if k in t]
        if found:
            hits.append((i + 1, sorted(set(found)), t))
            hit_pages.append(i + 1)
        if (i + 1) % 50 == 0:
            print(f"scanned {i+1}/{n}")

    summary = []
    for p, ks, _ in hits:
        summary.append(f"p{p}: {', '.join(ks)}")
    (OUT / "03_keyword_index.txt").write_text("\n".join(summary), encoding="utf-8")
    print("hit pages", len(hits))

    # Dump full text of high-priority pages (Modbus / register / TCP)
    priority_re = re.compile(r"Modbus|寄存器|通讯|通信|Dashboard|二次开发|TCP/IP|保持寄存器|功能码", re.I)
    chunks = []
    for p, ks, t in hits:
        if priority_re.search(" ".join(ks)) or priority_re.search(t[:500]):
            chunks.append(f"\n{'='*20} PAGE {p} {'='*20}\n关键词: {', '.join(ks)}\n\n{t}")
    (OUT / "04_comm_pages.txt").write_text("\n".join(chunks), encoding="utf-8")
    print("comm chunks", len(chunks))
    print("done ->", OUT)


if __name__ == "__main__":
    main()
