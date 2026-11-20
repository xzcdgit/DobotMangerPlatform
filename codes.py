"""状态码表：判定级别、取名称。"""


class Codes:
    def __init__(self, table):
        self.codes = table["codes"]
        self.retired = table.get("retired", {})
        self.station_codes = {k: set(v) for k, v in table["stationCodes"].items()}

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
