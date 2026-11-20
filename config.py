"""读取并校验 config.json。格式有误时抛出带中文说明的 ConfigError。"""
import ipaddress
import json
from pathlib import Path

MODES = ("sim", "modbus", "report")
COMMANDS = ("reset", "start", "stop")
COMMAND_MODES = ("dobot", "register")
REGISTER_TYPES = ("holding", "input")
STATION_FIELDS = ("no", "name", "ip", "port")
STATION_OPTIONAL = ("type", "group")

# Dobot map1 线圈（脚本地址 = PDU 地址）：附录 A.2
DEFAULT_COILS = {
    "start": 0,         # 开始
    "stop": 1,          # 停止
    "enable": 3,        # 上使能
    "disable": 4,       # 下使能
    "clear_alarm": 5,   # 清除报警
}

# 现场已占用、禁止当作监控动作/异常寄存器的地址（含多字寄存器占位）
BUSY_HOLDING_REGS = frozenset({
    2031, 2032, 2400, 3095, 3155, 3311, 3687, 3703,
    3751, 3752, 3753, 3754,  # 写程序号 F64
    3811, 3812, 3813, 3814,  # EAP Seg 出
    3911, 3912, 3913, 3914,  # EAP Seg 入
    4600, 5678, 5679, 8888,
})

DEFAULT_MODBUS = {
    # 监控专用：与 EAP/旋转等业务寄存器分离；动作码与异常码分两个地址
    "action_register": 4100,
    "fault_register": 4101,
    "register_type": "holding",
    "slave_id": 1,
    "timeout": 1.0,
    "offline_after_failures": 3,
    # dobot：按手册写线圈；register：写保持寄存器（旧占位方案）
    "command_mode": "dobot",
    "coil_pulse_ms": 200,
    "coil_gap_ms": 200,           # 清报警→下使能之间的短间隔（信号边沿）
    "disable_settle_ms": 3000,    # 下使能后至少等待，再开始上使能
    "enable_settle_ms": 5000,     # 上使能后至少等待，再结束复位
    "enable_status_addr": 7,      # map1 触点「使能状态」；null 则只按 settle 等待
    "enable_timeout_ms": 30000,   # 轮询使能状态的最长等待
    "enable_poll_ms": 250,
    # map1 触点（FC02 / GetInBits 脚本地址）。注意：地址3「运行」多为运动中，Wait 时经常为0，
    # 不能用来判断脚本是否在跑；停机看地址1「停止状态」，暂停2，报警4。
    "stop_status_addr": 1,        # 停止状态；null=不读
    "paused_status_addr": 2,      # 暂停状态；null=不读
    "running_status_addr": 3,     # 运动/运行触点（仅展示，不单独判停机）；null=不读
    "alarm_status_addr": 4,       # 报警状态；null=不读
    "coils": dict(DEFAULT_COILS),
    "command_register": None,
    "command_values": {"reset": 1, "start": 2, "stop": 3},
}


class ConfigError(ValueError):
    pass


def _is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _int_in(value, lo, hi, label):
    if not _is_int(value) or not lo <= value <= hi:
        raise ConfigError("%s 必须是 %d~%d 的整数，当前值：%r" % (label, lo, hi, value))
    return value


def _station(raw, position):
    label = "stations 第 %d 项" % position
    if not isinstance(raw, dict):
        raise ConfigError('%s 必须是对象，例如 {"no": 1, "name": "站名", "ip": "192.168.5.71", "port": 502}' % label)
    missing = [k for k in STATION_FIELDS if k not in raw]
    if missing:
        raise ConfigError("%s 缺少字段：%s" % (label, "、".join(missing)))
    unknown = [k for k in raw if k not in STATION_FIELDS + STATION_OPTIONAL and not k.startswith("_")]
    if unknown:
        raise ConfigError("%s 有无法识别的字段：%s（可用字段：no、name、ip、port、type、group）" % (label, "、".join(unknown)))

    no = _int_in(raw["no"], 1, 9999, label + " 的 no（序号）")
    name = raw["name"]
    if not isinstance(name, str) or not name.strip() or len(name.strip()) > 30:
        raise ConfigError("%s 的 name（站名）必须是 1~30 个字符的文字，当前值：%r" % (label, name))
    try:
        if not isinstance(raw["ip"], str):
            raise ValueError
        ip = ipaddress.IPv4Address(raw["ip"].strip())
    except ValueError:  # AddressValueError 是它的子类
        raise ConfigError("%s 的 ip 不是合法的 IPv4 地址：%r" % (label, raw["ip"])) from None
    port = _int_in(raw["port"], 1, 65535, label + " 的 port（端口）")
    kind = raw.get("type", "")
    if not isinstance(kind, str):
        raise ConfigError("%s 的 type 必须是文字，当前值：%r" % (label, kind))
    group = raw.get("group", "")
    if not isinstance(group, str):
        raise ConfigError("%s 的 group 必须是文字，当前值：%r" % (label, group))
    if len(group.strip()) > 30:
        raise ConfigError("%s 的 group（产线分组）不能超过 30 个字" % label)
    return {"no": no, "id": str(no), "name": name.strip(), "ip": str(ip), "port": port,
            "type": kind.strip(), "group": group.strip()}


def _stations(raw):
    if not isinstance(raw, list) or not raw:
        raise ConfigError("stations 必须是非空数组，每个工作站填写 no、name、ip、port")
    stations = [_station(item, i) for i, item in enumerate(raw, start=1)]
    seen_no, seen_addr = {}, {}
    for s in stations:
        if s["no"] in seen_no:
            raise ConfigError("序号重复：no=%d（%s 与 %s）" % (s["no"], seen_no[s["no"]], s["name"]))
        addr = (s["ip"], s["port"])
        if addr in seen_addr:
            raise ConfigError("IP+端口重复：%s:%d（%s 与 %s）" % (s["ip"], s["port"], seen_addr[addr], s["name"]))
        seen_no[s["no"]], seen_addr[addr] = s["name"], s["name"]
    # 保持 config.json 中 stations 数组的书写顺序（总览/下拉与配置一致）
    return stations


def _coils(raw):
    if raw is None:
        raw = {}
    if not isinstance(raw, dict):
        raise ConfigError("modbus.coils 必须是对象")
    merged = {**DEFAULT_COILS, **raw}
    unknown = [k for k in merged if k not in DEFAULT_COILS]
    if unknown:
        raise ConfigError("modbus.coils 有无法识别的字段：%s" % "、".join(unknown))
    for name in DEFAULT_COILS:
        _int_in(merged[name], 0, 9998, "modbus.coils." + name)
    return {k: merged[k] for k in DEFAULT_COILS}


def _modbus(raw):
    if raw is None:
        raw = {}
    if not isinstance(raw, dict):
        raise ConfigError("modbus 必须是对象")
    coils_raw = raw.get("coils", DEFAULT_COILS)
    patched = {k: v for k, v in raw.items() if k != "coils"}
    # 兼容旧配置：仅有 status_register 时当作动作寄存器，异常寄存器默认 +1
    if "action_register" not in patched and "status_register" in patched:
        patched["action_register"] = patched["status_register"]
        patched.setdefault("fault_register", int(patched["status_register"]) + 1)
    m = {**DEFAULT_MODBUS, **patched}
    m.pop("status_register", None)
    _int_in(m["action_register"], 0, 65535, "modbus.action_register")
    _int_in(m["fault_register"], 0, 65535, "modbus.fault_register")
    if m["action_register"] == m["fault_register"]:
        raise ConfigError("modbus.action_register 与 fault_register 不能相同")
    for key in ("action_register", "fault_register"):
        if m[key] in BUSY_HOLDING_REGS:
            raise ConfigError("%s=%d 与现场业务寄存器冲突，请另选监控专用地址" % (key, m[key]))
    if m["register_type"] not in REGISTER_TYPES:
        raise ConfigError("modbus.register_type 只能是 holding 或 input")
    _int_in(m["slave_id"], 0, 255, "modbus.slave_id")
    if not _is_number(m["timeout"]) or m["timeout"] <= 0:
        raise ConfigError("modbus.timeout 必须是大于 0 的数字（秒）")
    _int_in(m["offline_after_failures"], 1, 1000, "modbus.offline_after_failures")
    if m["command_mode"] not in COMMAND_MODES:
        raise ConfigError("modbus.command_mode 只能是 dobot 或 register")
    _int_in(m["coil_pulse_ms"], 1, 5000, "modbus.coil_pulse_ms")
    _int_in(m["coil_gap_ms"], 0, 5000, "modbus.coil_gap_ms")
    _int_in(m["disable_settle_ms"], 0, 120000, "modbus.disable_settle_ms")
    _int_in(m["enable_settle_ms"], 0, 120000, "modbus.enable_settle_ms")
    _int_in(m["enable_timeout_ms"], 100, 300000, "modbus.enable_timeout_ms")
    _int_in(m["enable_poll_ms"], 50, 5000, "modbus.enable_poll_ms")
    if m["enable_status_addr"] is not None:
        _int_in(m["enable_status_addr"], 0, 9998, "modbus.enable_status_addr")
    for key in ("stop_status_addr", "paused_status_addr", "running_status_addr", "alarm_status_addr"):
        if m.get(key) is not None:
            _int_in(m[key], 0, 9998, "modbus." + key)
    coils = _coils(coils_raw)
    if m["command_register"] is not None:
        _int_in(m["command_register"], 0, 65535, "modbus.command_register")
    if m["command_mode"] == "register" and m["command_register"] is None:
        raise ConfigError("modbus.command_mode 为 register 时必须填写 command_register")
    values = m["command_values"]
    if not isinstance(values, dict) or any(c not in values for c in COMMANDS):
        raise ConfigError("modbus.command_values 必须同时包含 reset、start、stop")
    for c in COMMANDS:
        _int_in(values[c], 0, 65535, "modbus.command_values." + c)
    return {**m, "coils": coils, "command_values": {c: values[c] for c in COMMANDS}}


def _beats(raw):
    """config.json 的 _beats：本线动作码顺序。缺省时前端用内置工位流程。"""
    if raw is None:
        return []
    if not isinstance(raw, list):
        raise ConfigError("_beats 必须是数组")
    codes, seen = [], set()
    for i, item in enumerate(raw, start=1):
        if _is_int(item):
            code = item
        elif isinstance(item, dict) and _is_int(item.get("code")):
            code = item["code"]
        else:
            raise ConfigError("_beats 第 %d 项必须带整数 code" % i)
        _int_in(code, 0, 65535, "_beats 第 %d 项的 code" % i)
        if code not in seen:
            seen.add(code)
            codes.append(code)
    return codes


def validate(raw):
    """校验并返回规范化后的新配置，不修改传入对象。"""
    if not isinstance(raw, dict):
        raise ConfigError("配置文件顶层必须是 JSON 对象")
    if "arms" in raw and "stations" not in raw:
        raise ConfigError("配置项 arms 已改名为 stations，每项字段为 no、name、ip、port")
    mode = raw.get("mode", "sim")
    if mode not in MODES:
        raise ConfigError("mode 只能是 %s" % "、".join(MODES))
    interval = raw.get("poll_interval", 1.0)
    if not _is_number(interval) or interval <= 0:
        raise ConfigError("poll_interval 必须是大于 0 的数字（秒）")
    pin = raw.get("control_pin", "")
    if not isinstance(pin, str):
        raise ConfigError("control_pin 必须是文字，留空表示不需要操作密码")
    return {
        "port": _int_in(raw.get("port", 8080), 1, 65535, "port"),
        "mode": mode,
        "poll_interval": float(interval),
        "control_pin": pin,
        "modbus": _modbus(raw.get("modbus")),
        "stations": _stations(raw.get("stations")),
        "beats": _beats(raw.get("_beats")),
    }


def load(path):
    text = Path(path).read_text(encoding="utf-8-sig")
    try:
        raw = json.loads(text)
    except json.JSONDecodeError as e:
        raise ConfigError("%s 不是合法的 JSON：第 %d 行第 %d 列，%s" % (Path(path).name, e.lineno, e.colno, e.msg)) from None
    return validate(raw)
