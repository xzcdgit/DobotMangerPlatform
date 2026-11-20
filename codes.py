"""状态码表：从根目录 codes.json 加载（改表重启即可，不必改源码）。"""
from __future__ import annotations

import json
from pathlib import Path


class CodesError(ValueError):
    pass


def _require_dict(obj, label):
    if not isinstance(obj, dict):
        raise CodesError("%s 必须是对象" % label)
    return obj


def validate_table(raw):
    """校验并返回规范化表；忽略 _说明 等以下划线开头的注释字段。"""
    raw = _require_dict(raw, "状态码表顶层")
    codes_raw = _require_dict(raw.get("codes"), "codes")
    stations_raw = _require_dict(raw.get("stationCodes"), "stationCodes")
    retired_raw = raw.get("retired", {})
    if not isinstance(retired_raw, dict):
        raise CodesError("retired 必须是对象")

    codes = {}
    for key, info in codes_raw.items():
        label = "codes.%s" % key
        try:
            num = int(key)
        except (TypeError, ValueError):
            raise CodesError("%s：键必须是数字状态码" % label) from None
        if not 0 <= num <= 65535:
            raise CodesError("%s：状态码须在 0~65535" % label)
        info = _require_dict(info, label)
        for field in ("category", "name", "when", "next"):
            if not isinstance(info.get(field), str) or not info[field].strip():
                raise CodesError("%s：缺少文字字段 %s" % (label, field))
        if not isinstance(info.get("stop"), bool):
            raise CodesError("%s：stop 必须是 true/false" % label)
        codes[str(num)] = {
            "category": info["category"].strip(),
            "name": info["name"].strip(),
            "when": info["when"].strip(),
            "next": info["next"].strip(),
            "stop": info["stop"],
            "stations": str(info.get("stations") or "").strip(),
            "source": str(info.get("source") or "").strip(),
        }

    station_codes = {}
    for stype, lst in stations_raw.items():
        if not isinstance(stype, str) or not stype.strip():
            raise CodesError("stationCodes 的键必须是工位类型名称")
        if not isinstance(lst, list):
            raise CodesError("stationCodes.%s 必须是数组" % stype)
        nums = []
        for i, item in enumerate(lst):
            try:
                n = int(item)
            except (TypeError, ValueError):
                raise CodesError("stationCodes.%s[%d] 必须是数字" % (stype, i)) from None
            if str(n) not in codes:
                raise CodesError("stationCodes.%s 引用了未定义码 %s" % (stype, n))
            nums.append(n)
        station_codes[stype.strip()] = nums

    retired = {}
    for key, info in retired_raw.items():
        label = "retired.%s" % key
        try:
            int(key)
        except (TypeError, ValueError):
            raise CodesError("%s：键必须是数字" % label) from None
        info = _require_dict(info, label)
        use = info.get("use")
        if use is None or str(use).strip() == "":
            raise CodesError("%s：需要 use（改用哪个码）" % label)
        retired[str(int(key))] = {
            "use": str(use).strip(),
            "reason": str(info.get("reason") or "").strip(),
        }

    if not codes:
        raise CodesError("codes 不能为空")
    return {"codes": codes, "stationCodes": station_codes, "retired": retired}


def load(path):
    path = Path(path)
    try:
        text = path.read_text(encoding="utf-8-sig")
    except OSError as e:
        raise CodesError("无法读取状态码表 %s：%s" % (path.name, e)) from e
    try:
        raw = json.loads(text)
    except json.JSONDecodeError as e:
        raise CodesError("%s 不是合法 JSON：第 %d 行第 %d 列，%s" % (path.name, e.lineno, e.colno, e.msg)) from None
    return validate_table(raw)


class Codes:
    def __init__(self, table):
        table = validate_table(table)
        self.codes = table["codes"]
        self.retired = table["retired"]
        self.station_codes = {k: set(v) for k, v in table["stationCodes"].items()}
        self.raw = {
            "codes": self.codes,
            "stationCodes": {k: sorted(v) for k, v in self.station_codes.items()},
            "retired": self.retired,
        }

    def level_of(self, code):
        if code is None:
            return "offline"
        info = self.codes.get(str(code))
        if info is None:
            return "unknown"
        if info["stop"]:
            return "stop"
        return "warn" if info["category"] == "过程异常" else "ok"

    def text_of(self, code):
        if code is None:
            return "无响应"
        info = self.codes.get(str(code))
        if info:
            return info["name"]
        old = self.retired.get(str(code))
        return "已停用，改用 %s" % old["use"] if old else "表中无此状态码"

    def pool(self, station_type):
        return sorted(self.station_codes.get(station_type, ()))
