# -*- coding: utf-8 -*-
from pathlib import Path
from pypdf import PdfReader

PDF = Path(r"C:\Users\xiazhenc\Desktop\DobotStudio Pro 用户手册_V4.6.7_20260624_cn.pdf")
OUT = Path(r"D:\机器人可视化平台\_dobot_manual_extract")
reader = PdfReader(str(PDF))

# Focus page ranges (1-based), tuned from keyword index + TOC
RANGES = [
    ("front_modbus_toc", range(1, 12)),
    ("io_modbus_config", range(70, 80)),
    ("modbus_assistant", range(168, 182)),
    ("comm_settings", range(258, 276)),
    ("blocks_modbus_tcp", range(340, 365)),
    ("script_tcp_modbus", range(455, 480)),
    ("appendix_A", range(1, 15)),  # early appendix summary pages if any
    ("appendix_A_detail", range(460, 480)),
    ("python_modbus", range(560, 575)),
]

# Also find pages that literally contain "附录A" or "A.5 保持寄存器"
markers = []
for i, page in enumerate(reader.pages):
    t = page.extract_text() or ""
    if "附录A" in t or "A.5 保持寄存器" in t or "ModbusCreate" in t or "SetHoldRegs" in t:
        if any(k in t for k in ("附录A", "A.5", "ModbusCreate", "SetHoldRegs", "保持寄存器定义")):
            markers.append((i + 1, t[:120].replace("\n", " ")))
(OUT / "05_markers.txt").write_text("\n".join(f"p{p}: {s}" for p, s in markers), encoding="utf-8")
print("markers", len(markers))
for p, s in markers[:40]:
    print(f"p{p}: {s}")

# Dump denser extracts for ModbusCreate / SetHoldRegs / Appendix A pages
want = set()
for p, tpreview in markers:
    want.add(p)
# expand neighbors
expanded = set()
for p in want:
    for d in range(-1, 3):
        if 1 <= p + d <= len(reader.pages):
            expanded.add(p + d)

parts = []
for p in sorted(expanded):
    t = reader.pages[p - 1].extract_text() or ""
    parts.append(f"\n{'='*20} PAGE {p} {'='*20}\n{t}")
(OUT / "06_modbus_api_and_regs.txt").write_text("\n".join(parts), encoding="utf-8")
print("wrote pages", len(expanded), "-> 06_modbus_api_and_regs.txt")
