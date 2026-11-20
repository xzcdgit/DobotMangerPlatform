"""从 美国线状态码对照表.xlsx 生成根目录 codes.json。表更新后重新运行即可。"""
import json
import sys
from pathlib import Path

import openpyxl

HERE = Path(__file__).resolve().parent
XLSX = HERE.parent / "美国线状态码对照表.xlsx"
OUT = HERE / "codes.json"


def main() -> None:
    wb = openpyxl.load_workbook(XLSX)

    codes = {}
    for row in wb["状态码对照表"].iter_rows(min_row=2, values_only=True):
        if row[0] is None:
            continue
        codes[str(row[0])] = {
            "category": row[1],
            "name": row[2],
            "when": row[3],
            "next": row[4],
            "stop": row[5] == "停机",
            "stations": row[6],
            "source": row[7],
        }

    station_codes = {}
    for row in wb["按工位查看"].iter_rows(min_row=2, values_only=True):
        if row[0] is None or row[1] is None:
            continue
        station_codes.setdefault(row[0], []).append(row[1])

    retired = {}
    for row in wb["停用码"].iter_rows(min_row=2, values_only=True):
        if row[0] is not None:
            retired[str(row[0])] = {"use": str(row[1]), "reason": row[2]}

    OUT.write_text(
        json.dumps(
            {
                "_说明": "状态码对照表（独立配置）。增删改本文件后重启软件即可生效，不必改源码。",
                "codes": codes,
                "stationCodes": station_codes,
                "retired": retired,
            },
            ensure_ascii=False,
            indent=1,
        ),
        encoding="utf-8",
    )
    print(f"{len(codes)} codes, {len(station_codes)} station types, {len(retired)} retired -> {OUT}")


if __name__ == "__main__":
    sys.exit(main())
