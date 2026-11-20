"""监控核心：各工作站的当前状态、状态变化记录、日志、下发命令、测试/真实模式切换。"""
import json
import logging
import os
import struct
import threading
import time
from collections import deque

import modbus
from config import COMMANDS
from sim import Sim

log = logging.getLogger("monitor")

HISTORY_PER_STATION = 120
EVENTS_KEEP = 300
ALERTS_KEEP = 300
COMMAND_LABEL = {"reset": "复位", "start": "开始", "stop": "停止"}
TEST = "sim"  # 测试模式对应的内部名称；真实模式为 modbus 或 report


def new_station(s):
    return {**s, "code": None, "action": None, "fault": None, "known": False,
            "since": time.time(), "lastSeen": None, "failures": 0,
            "stopped": False, "paused": False, "running": None, "alarmed": False,
            "history": deque(maxlen=HISTORY_PER_STATION)}


class Monitor:
    """mode == "sim" 是测试模式（虚拟状态）；其余为真实模式（读取真实状态）。"""

    def __init__(self, cfg, codes, logs, host, mode_path=None):
        self.cfg = cfg
        self.codes = codes
        self.logs = logs
        self.host = host
        self.lock = threading.Lock()
        self._switch_lock = threading.Lock()
        self.mode_path = str(mode_path) if mode_path else None
        self.live_mode = "modbus" if cfg["mode"] == TEST else cfg["mode"]
        self.mode = self._initial_mode()
        self._gen = 0  # 每次切换模式加一，旧线程发现代数变了就退出
        self.events = deque(maxlen=EVENTS_KEEP)
        self.alerts = deque(maxlen=ALERTS_KEEP)
        self.sim = None
        self.sim_factory = lambda mon: Sim(mon, mon.codes)
        self.stations = {s["id"]: new_station(s) for s in cfg["stations"]}

    def _initial_mode(self):
        """上次在页面上选的模式优先；config.json 的 mode 改过之后，旧选择作废。"""
        if self.mode_path:
            try:
                with open(self.mode_path, encoding="utf-8") as f:
                    saved = json.load(f)
                if saved.get("cfgMode") == self.cfg["mode"]:
                    return TEST if saved.get("test") else self.live_mode
            except (OSError, ValueError, AttributeError):
                pass
        return self.cfg["mode"]

    def _save_mode(self):
        if not self.mode_path:
            return
        tmp = self.mode_path + ".tmp"
        try:
            os.makedirs(os.path.dirname(self.mode_path) or ".", exist_ok=True)
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump({"test": self.mode == TEST, "cfgMode": self.cfg["mode"]}, f)
            os.replace(tmp, self.mode_path)
        except OSError:
            log.exception("保存运行模式失败：%s", self.mode_path)

    def _severity_level_code(self, st):
        """卡片等级跟动作码；异常码只做告警/角标，不再用残留故障把整卡盖成停机。"""
        action = st.get("action")
        if action is not None:
            return action
        return st.get("code")

    def record(self, st, code, now, action=None, fault=None):
        """记录一次读数；调用方须持有 lock。code 为 None 表示离线。
        code/action 表示工艺状态；fault 表示异常，二者分寄存器，互不覆盖。"""
        was_known = st["known"]
        st["known"] = True
        if code is not None:
            st["lastSeen"] = now
        if action is not None:
            st["action"] = action
        prev_fault = st.get("fault") or 0
        if fault is not None:
            st["fault"] = fault or 0
        fault_now = st.get("fault") or 0
        status_same = was_known and st["code"] == code
        fault_same = fault is None or fault_now == prev_fault
        if status_same and fault_same:
            return

        prev, prev_since = st["code"], st["since"]
        if not status_same:
            st["code"], st["since"] = code, now
            st["history"].append({"t": now, "code": code, "action": st.get("action"), "fault": st.get("fault")})

        level_code = self._severity_level_code(st)
        level = self.codes.level_of(level_code if code is not None else None)
        ev = {"t": now, "id": st["id"], "no": st["no"], "name": st["name"], "type": st["type"],
              "from": prev if was_known else None, "code": code, "level": level,
              "action": st.get("action"), "fault": st.get("fault")}
        if not status_same or not fault_same:
            self.events.append(ev)
        # 告警：看异常码升降；无异常时看动作码等级
        alert_code = fault_now if (not fault_same and fault_now) else (None if fault_same and status_same else level_code)
        if alert_code is None and not fault_same and not fault_now and prev_fault:
            # 异常清除
            recovered = True
            level = "ok"
            alert_code = code
        else:
            recovered = was_known and self.codes.level_of(prev_fault if prev_fault else prev) != "ok" and level == "ok"
        if (not fault_same and (fault_now or prev_fault)) or ((not status_same) and (level != "ok" or recovered)):
            if not fault_same and fault_now:
                level = self.codes.level_of(fault_now)
                alert_code = fault_now
            self.alerts.append(ev)
            entry = {"t": now, "kind": "recover" if recovered else "fault", "level": level,
                     "no": st["no"], "name": st["name"], "ip": st["ip"], "port": st["port"],
                     "code": alert_code, "text": self.codes.text_of(alert_code),
                     "from": prev if was_known else None}
            if recovered:
                entry["prevSec"] = round(now - prev_since)
                entry["detail"] = "此前 %s %s" % ("离线" if prev is None else prev, self.codes.text_of(prev))
            if self.mode == TEST:
                entry["test"] = True
            self.logs.append(entry)

    def _read_robot_bits(self, st, cfg):
        """读 map1 触点：停止(1)/暂停(2)/运行(3)/报警(4)。返回 (stopped, paused, running, alarmed)。"""
        keys = ("stop_status_addr", "paused_status_addr", "running_status_addr", "alarm_status_addr")
        addrs = [cfg.get(k) for k in keys if cfg.get(k) is not None]
        if not addrs:
            return None, None, None, None
        lo, hi = min(addrs), max(addrs)
        bits = modbus.read_discretes(st["ip"], st["port"], cfg["slave_id"], lo, hi - lo + 1, cfg["timeout"])

        def at(addr):
            if addr is None:
                return None
            return bits[addr - lo]

        return (
            at(cfg.get("stop_status_addr")),
            at(cfg.get("paused_status_addr")),
            at(cfg.get("running_status_addr")),
            at(cfg.get("alarm_status_addr")),
        )

    def _display_level(self, st):
        """页面等级：报警/停止状态/暂停触点优先；不用「运行」触点判停（Wait 时经常为0）。"""
        if st.get("code") is None:
            return "offline"
        if st.get("alarmed"):
            return "stop"
        if st.get("stopped"):
            return "stop"
        if st.get("paused"):
            return "warn"
        return self.codes.level_of(self._severity_level_code(st))

    # ---------- Modbus 轮询 ----------
    def poll_loop(self, station_id, gen=None):
        cfg = self.cfg["modbus"]
        gen = self._gen if gen is None else gen
        while gen == self._gen:
            st = self.stations.get(station_id)
            if st is None or gen != self._gen:
                return
            try:
                action = modbus.read_register(st["ip"], st["port"], cfg["slave_id"], cfg["action_register"],
                                              cfg["register_type"], cfg["timeout"])
                fault = modbus.read_register(st["ip"], st["port"], cfg["slave_id"], cfg["fault_register"],
                                             cfg["register_type"], cfg["timeout"])
                # 动作码与异常码分寄存器：状态轨迹只跟动作码；异常单独存放
                code = action
                try:
                    stopped, paused, running, alarmed = self._read_robot_bits(st, cfg)
                except (OSError, struct.error, ValueError):
                    stopped, paused, running, alarmed = None, None, None, None
                with self.lock:
                    if gen != self._gen:
                        return  # 读的过程中已切换模式，这个读数不属于当前模式
                    st["failures"] = 0
                    if stopped is not None:
                        st["stopped"] = stopped
                    if paused is not None:
                        st["paused"] = paused
                    if running is not None:
                        st["running"] = running
                    if alarmed is not None:
                        st["alarmed"] = alarmed
                    self.record(st, code, time.time(), action=action, fault=fault or 0)
            except (OSError, struct.error):
                with self.lock:
                    if gen != self._gen:
                        return
                    st["failures"] += 1
                    if st["failures"] >= cfg["offline_after_failures"]:
                        st["running"] = None
                        self.record(st, None, time.time(), action=None, fault=None)
            except Exception:  # 单个站的意外错误不能让该站的轮询线程退出
                log.exception("轮询工作站 %s 出错", station_id)
            time.sleep(self.cfg["poll_interval"])

    def start(self, sim_factory=None):
        if sim_factory is not None:
            self.sim_factory = sim_factory
        with self._switch_lock:
            self._launch()

    def _launch(self):
        """按当前模式启动后台线程；调用方须持有 _switch_lock。"""
        gen = self._gen
        if self.mode == "modbus":
            for sid in self.stations:
                threading.Thread(target=self.poll_loop, args=(sid, gen), daemon=True).start()
        elif self.mode == TEST:
            with self.lock:
                if self.sim is None:
                    self.sim = self.sim_factory(self)
                sim = self.sim
            threading.Thread(target=sim.run, args=(gen,), daemon=True).start()

    def set_mode(self, test, client):
        """切换测试/真实模式：旧线程退出，工作站状态、事件、提醒全部清空，避免两种数据混在一起。"""
        target = TEST if test else self.live_mode
        with self._switch_lock:
            if target == self.mode:
                return {"mode": self.mode, "changed": False}
            now = time.time()
            with self.lock:
                self._gen += 1
                self.mode = target
                self.stations = {s["id"]: new_station(s) for s in self.cfg["stations"]}
                self.events.clear()
                self.alerts.clear()
                self.sim = self.sim_factory(self) if target == TEST else None
            self._save_mode()
            self.logs.append({"t": now, "kind": "mode", "ok": True, "no": "", "name": "", "ip": "", "port": "",
                              "client": client, "test": bool(test),
                              "text": "切换到测试模式" if test else "切换到真实模式",
                              "detail": "状态改为虚拟模拟数据" if test else "状态改为读取真实设备"})
            self._launch()
        return {"mode": self.mode, "changed": True}

    # ---------- 操作员命令 ----------
    def send_command(self, station_id, command, client):
        """下发复位/开始/停止并写操作日志。返回 {ok, detail}。"""
        if command not in COMMANDS:
            raise ValueError("命令只能是 reset、start、stop")
        if station_id not in self.stations:
            raise KeyError(station_id)
        now = time.time()
        with self.lock:
            is_test = self.mode == TEST
            st = self.stations[station_id]
            if is_test:
                ok, detail = True, self.sim.apply(st, command, now)
        if not is_test:
            ok, detail = self._write_command(st, command)  # 网络 I/O，不能持有全局锁
        entry = {"t": now, "kind": "command", "command": command, "ok": ok, "no": st["no"],
                 "name": st["name"], "ip": st["ip"], "port": st["port"], "client": client,
                 "text": COMMAND_LABEL[command], "detail": detail}
        if is_test:
            entry["test"] = True
        self.logs.append(entry)
        return {"ok": ok, "detail": detail}

    def _can_control(self):
        mb = self.cfg["modbus"]
        if mb["command_mode"] == "dobot":
            return True
        return mb["command_register"] is not None

    def _pulse(self, st, coil_name):
        mb = self.cfg["modbus"]
        addr = mb["coils"][coil_name]
        modbus.pulse_coil(st["ip"], st["port"], mb["slave_id"], addr, mb["timeout"], mb["coil_pulse_ms"])
        return addr

    def _wait_enable_state(self, st, want_on, settle_ms):
        """先等 settle（机械到位），再轮询 map1「使能状态」直到目标或超时。"""
        mb = self.cfg["modbus"]
        time.sleep(max(0, settle_ms) / 1000.0)
        addr = mb.get("enable_status_addr")
        if addr is None:
            return True, "已等待 %d ms" % settle_ms
        deadline = time.time() + mb["enable_timeout_ms"] / 1000.0
        poll = mb["enable_poll_ms"] / 1000.0
        last = None
        while True:
            last = modbus.read_discrete(st["ip"], st["port"], mb["slave_id"], addr, mb["timeout"])
            if bool(last) == bool(want_on):
                return True, "使能状态已为%s" % ("ON" if want_on else "OFF")
            if time.time() >= deadline:
                return False, "等待使能状态变为%s超时（当前=%s，地址%d）" % (
                    "ON" if want_on else "OFF", "ON" if last else "OFF", addr)
            time.sleep(poll)

    def _write_dobot(self, st, command):
        """按 Dobot 附录 A.2 写 map1 线圈；复位=清报警→下使能(等)→上使能(等)。"""
        mb = self.cfg["modbus"]
        gap = mb["coil_gap_ms"] / 1000.0
        try:
            if command == "start":
                addr = self._pulse(st, "start")
                return True, "已脉冲开始线圈 %d（上升沿）" % addr
            if command == "stop":
                addr = self._pulse(st, "stop")
                return True, "已脉冲停止线圈 %d（上升沿）" % addr
            # reset：清除报警 → 下使能并等待完成 → 上使能并等待完成
            steps = []
            addr = self._pulse(st, "clear_alarm")
            steps.append("清除报警(线圈%d)" % addr)
            time.sleep(gap)

            addr = self._pulse(st, "disable")
            steps.append("下使能(线圈%d)" % addr)
            ok, note = self._wait_enable_state(st, False, mb["disable_settle_ms"])
            steps.append(note)
            if not ok:
                return False, "复位中断（下使能未完成）：" + " → ".join(steps)

            addr = self._pulse(st, "enable")
            steps.append("上使能(线圈%d)" % addr)
            ok, note = self._wait_enable_state(st, True, mb["enable_settle_ms"])
            steps.append(note)
            if not ok:
                return False, "复位中断（上使能未完成）：" + " → ".join(steps)

            return True, "复位完成：" + " → ".join(steps)
        except OSError as e:
            log.warning("Dobot 线圈命令失败 %s:%d %s %s", st["ip"], st["port"], command, e)
            return False, "线圈写入失败：%s" % e

    def _write_register_command(self, st, command):
        mb = self.cfg["modbus"]
        reg = mb["command_register"]
        if reg is None:
            return False, "未配置 modbus.command_register，命令未发送"
        value = mb["command_values"][command]
        try:
            modbus.write_register(st["ip"], st["port"], mb["slave_id"], reg, value, mb["timeout"])
        except OSError as e:
            log.warning("命令写入失败 %s:%d %s", st["ip"], st["port"], e)
            return False, "写入寄存器 %d=%d 失败：%s" % (reg, value, e)
        return True, "已写入寄存器 %d = %d" % (reg, value)

    def _write_command(self, st, command):
        if self.cfg["modbus"]["command_mode"] == "dobot":
            return self._write_dobot(st, command)
        return self._write_register_command(st, command)

    # ---------- 页面数据 ----------
    def snapshot(self):
        now = time.time()
        with self.lock:
            stations = [
                {"id": s["id"], "no": s["no"], "name": s["name"], "ip": s["ip"], "port": s["port"],
                 "type": s["type"], "group": s.get("group", ""), "code": s["code"],
                 "action": s.get("action"), "fault": s.get("fault"),
                 "level": self._display_level(s),
                 "since": s["since"], "lastSeen": s["lastSeen"],
                 "stopped": bool(s.get("stopped")), "paused": bool(s.get("paused")),
                 "running": s.get("running"), "alarmed": bool(s.get("alarmed")),
                 "known": s["known"], "history": list(s["history"])[-80:]}
                for s in self.stations.values()
            ]
            alerts = list(self.alerts)[-100:]
            mode = self.mode
        return {"now": now, "mode": mode, "test": mode == TEST, "liveMode": self.live_mode,
                "host": self.host.get(), "pinRequired": bool(self.cfg["control_pin"]),
                "canControl": mode == TEST or self._can_control(),
                "commandMode": self.cfg["modbus"]["command_mode"],
                "pollInterval": self.cfg["poll_interval"],
                "actionRegister": self.cfg["modbus"]["action_register"],
                "faultRegister": self.cfg["modbus"]["fault_register"],
                "stations": stations, "alerts": alerts}
