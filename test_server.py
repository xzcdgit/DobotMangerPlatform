import json
import socket
import struct
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest import mock

import config
import hostinfo
import modbus
import server
import store
from codes import Codes
from monitor import Monitor
from sim import Sim

TABLE = json.loads((server.HERE / "codes.json").read_text(encoding="utf-8"))
CODES = Codes(TABLE)


class FakeModbus:
    """应答功能码 02/03/04/05/06；mode: ok / exception / close / badecho。"""

    def __init__(self, value=204, mode="ok", enabled=True):
        self.value, self.mode = value, mode
        self.enabled = bool(enabled)  # map1 使能状态（地址 7）
        self.writes = []
        self.coils = []
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(5)
        self.port = self.sock.getsockname()[1]
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            with conn:
                req = conn.recv(12)
                if len(req) < 12 or self.mode == "close":
                    continue
                tid, _, _, unit, func, reg, arg = struct.unpack(">HHHBBHH", req)
                if self.mode == "exception":
                    conn.sendall(struct.pack(">HHHBBB", tid, 0, 3, unit, func | 0x80, 2))
                elif func in (5, 6):
                    if func == 5:
                        self.coils.append((reg, arg))
                        # 模拟下使能(4)/上使能(3) 上升沿后的使能状态变化
                        if arg == modbus.COIL_ON:
                            if reg == 4:
                                self.enabled = False
                            elif reg == 3:
                                self.enabled = True
                    else:
                        self.writes.append((reg, arg))
                    echo = arg + 1 if self.mode == "badecho" else arg
                    conn.sendall(struct.pack(">HHHBBHH", tid, 0, 6, unit, func, reg, echo))
                elif func == 2:
                    bit = 1 if (reg == 7 and self.enabled) else 0
                    conn.sendall(struct.pack(">HHHBBB", tid, 0, 4, unit, func, 1) + bytes([bit]))
                else:
                    conn.sendall(struct.pack(">HHHBBBH", tid, 0, 5, unit, func, 2, self.value))

    def close(self):
        self.sock.close()


def station(no, ip="192.168.5.71", port=502, **kw):
    return {"no": no, "name": "站%d" % no, "ip": ip, "port": port, **kw}


class ModbusTest(unittest.TestCase):
    def fake(self, **kw):
        f = FakeModbus(**kw)
        self.addCleanup(f.close)
        return f

    def read(self, f, rtype="holding"):
        return modbus.read_register("127.0.0.1", f.port, 1, 3800, rtype, 1.0)

    def test_reads_holding_register(self):
        self.assertEqual(self.read(self.fake(value=917)), 917)

    def test_reads_input_register(self):
        self.assertEqual(self.read(self.fake(value=65535), "input"), 65535)

    def test_exception_response_raises(self):
        with self.assertRaises(OSError):
            self.read(self.fake(mode="exception"))

    def test_closed_connection_raises(self):
        with self.assertRaises(OSError):
            self.read(self.fake(mode="close"))

    def test_refused_connection_raises(self):
        f = self.fake()
        f.close()
        with self.assertRaises(OSError):
            self.read(f)

    def test_write_register_sends_value(self):
        f = self.fake()
        modbus.write_register("127.0.0.1", f.port, 1, 3900, 2, 1.0)
        self.assertEqual(f.writes, [(3900, 2)])

    def test_write_register_rejects_bad_echo(self):
        f = self.fake(mode="badecho")
        with self.assertRaises(OSError):
            modbus.write_register("127.0.0.1", f.port, 1, 3900, 2, 1.0)

    def test_write_register_exception_raises(self):
        f = self.fake(mode="exception")
        with self.assertRaises(OSError):
            modbus.write_register("127.0.0.1", f.port, 1, 3900, 2, 1.0)

    def test_write_coil_and_pulse(self):
        f = self.fake()
        modbus.write_coil("127.0.0.1", f.port, 1, 5, True, 1.0)
        self.assertEqual(f.coils, [(5, modbus.COIL_ON)])
        f2 = self.fake()
        modbus.pulse_coil("127.0.0.1", f2.port, 1, 0, 1.0, pulse_ms=1)
        self.assertEqual(f2.coils, [(0, modbus.COIL_OFF), (0, modbus.COIL_ON), (0, modbus.COIL_OFF)])


class ConfigTest(unittest.TestCase):
    def check(self, raw, text):
        with self.assertRaises(config.ConfigError) as cm:
            config.validate(raw)
        self.assertIn(text, str(cm.exception))

    def test_valid_config_keeps_array_order(self):
        cfg = config.validate({"stations": [station(2, "192.168.5.2"), station(1, "192.168.5.1", type="灌装")]})
        self.assertEqual([s["no"] for s in cfg["stations"]], [2, 1])
        self.assertEqual(cfg["stations"][0]["type"], "")
        self.assertEqual(cfg["stations"][1]["type"], "灌装")
        self.assertEqual(cfg["stations"][0]["group"], "")
        self.assertEqual(cfg["stations"][1]["id"], "1")
        self.assertEqual(cfg["mode"], "sim")
        self.assertIsNone(cfg["modbus"]["command_register"])
        self.assertEqual(cfg["modbus"]["command_mode"], "dobot")
        self.assertEqual(cfg["modbus"]["coils"]["clear_alarm"], 5)

    def test_group_field_is_kept(self):
        cfg = config.validate({"stations": [
            station(73, "192.168.5.73", name="上内胆1", group="上内胆"),
            station(71, "192.168.5.71", name="上内胆2", group="上内胆"),
        ]})
        self.assertEqual([s["name"] for s in cfg["stations"]], ["上内胆1", "上内胆2"])  # 保持书写顺序
        self.assertEqual(cfg["stations"][0]["group"], "上内胆")

    def test_register_mode_requires_command_register(self):
        self.check({"stations": [station(1)], "modbus": {"command_mode": "register"}}, "command_register")

    def test_input_is_not_mutated(self):
        raw = {"stations": [station(1)]}
        config.validate(raw)
        self.assertEqual(raw, {"stations": [station(1)]})

    def test_missing_field(self):
        raw = station(1)
        del raw["port"]
        self.check({"stations": [raw]}, "缺少字段：port")

    def test_bad_ip(self):
        self.check({"stations": [station(1, ip="192.168.5.999")]}, "不是合法的 IPv4")

    def test_ip_must_be_text(self):
        self.check({"stations": [station(1, ip=123)]}, "不是合法的 IPv4")

    def test_bad_port(self):
        self.check({"stations": [station(1, port=70000)]}, "port")
        self.check({"stations": [station(1, port="502")]}, "port")
        self.check({"stations": [station(1, port=True)]}, "port")

    def test_bad_no(self):
        self.check({"stations": [station(0)]}, "no")
        self.check({"stations": [station(1.5)]}, "no")

    def test_empty_name(self):
        raw = station(1)
        raw["name"] = "  "
        self.check({"stations": [raw]}, "name")

    def test_duplicate_no(self):
        self.check({"stations": [station(1), station(1, "192.168.5.2")]}, "序号重复")

    def test_duplicate_address(self):
        self.check({"stations": [station(1), station(2)]}, "IP+端口重复")

    def test_same_ip_different_port_is_allowed(self):
        cfg = config.validate({"stations": [station(1, port=502), station(2, port=503)]})
        self.assertEqual(len(cfg["stations"]), 2)

    def test_unknown_field_is_reported_but_underscore_is_note(self):
        self.check({"stations": [station(1, colour="red")]}, "colour")
        cfg = config.validate({"stations": [station(1, _备注="x")]})
        self.assertNotIn("_备注", cfg["stations"][0])

    def test_old_arms_key_gets_migration_hint(self):
        self.check({"arms": [{"id": "71"}]}, "已改名为 stations")

    def test_stations_required(self):
        self.check({}, "stations")
        self.check({"stations": []}, "stations")

    def test_bad_mode(self):
        self.check({"mode": "x", "stations": [station(1)]}, "mode")

    def test_command_values_must_be_complete(self):
        self.check({"stations": [station(1)], "modbus": {"command_values": {"reset": 1}}}, "command_values")

    def test_load_reports_line_of_json_error(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "c.json"
            p.write_text('{\n  "port": 8080,\n  "stations": [,]\n}', encoding="utf-8")
            with self.assertRaises(config.ConfigError) as cm:
                config.load(p)
            self.assertIn("第 3 行", str(cm.exception))

    def test_shipped_config_is_valid(self):
        cfg = config.load(server.HERE / "config.json")
        self.assertGreaterEqual(len(cfg["stations"]), 1)
        self.assertTrue(cfg["stations"][0]["ip"])
        self.assertEqual(cfg["modbus"]["action_register"], 4100)
        self.assertEqual(cfg["modbus"]["fault_register"], 4101)
        self.assertIn(250, cfg["beats"])
        self.assertLess(cfg["beats"].index(250), cfg["beats"].index(200))
        from codes import load as load_codes
        table = load_codes(server.HERE / "codes.json")
        self.assertIn("204", table["codes"])
        self.assertIn("917", table["codes"])

    def test_busy_register_rejected(self):
        self.check({"stations": [station(1)], "modbus": {"action_register": 3811}}, "冲突")

    def test_beats_keep_config_order(self):
        cfg = config.validate({"stations": [station(1, type="上纸板")], "_beats": [
            {"code": 250, "stage": "料仓托举"}, {"code": 250}, 204, {"code": 187},
        ]})
        self.assertEqual(cfg["beats"], [250, 204, 187])

    def test_legacy_status_register_maps_to_action(self):
        cfg = config.validate({"stations": [station(1)], "modbus": {"status_register": 4100}})
        self.assertEqual(cfg["modbus"]["action_register"], 4100)
        self.assertEqual(cfg["modbus"]["fault_register"], 4101)
        self.assertNotIn("status_register", cfg["modbus"])


class StoreTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        self.logs = store.LogStore(self.dir / "logs")
        self.msgs = store.MessageStore(self.dir / "messages.json")

    def test_log_roundtrip_and_dates(self):
        t = time.mktime((2026, 11, 19, 8, 0, 0, 0, 0, -1))
        self.logs.append({"t": t, "kind": "fault", "level": "stop", "name": "a"})
        self.logs.append({"t": t + 60 * 60 * 24, "kind": "fault", "level": "warn", "name": "b"})
        self.assertEqual(self.logs.dates(), ["2026-11-20", "2026-11-19"])
        self.assertEqual([e["name"] for e in self.logs.read("2026-11-19")], ["a"])
        self.assertEqual(self.logs.read("2026-01-01"), [])

    def test_corrupt_log_line_is_skipped(self):
        (self.dir / "logs").mkdir()
        (self.dir / "logs" / "2026-11-19.jsonl").write_text('{"t": 1, "kind": "fault"}\n{坏行\n{"t": 2, "kind": "fault"}\n', encoding="utf-8")
        self.assertEqual(len(self.logs.read("2026-11-19")), 2)

    def test_parse_day_blocks_path_traversal(self):
        for bad in ("../config", "2026-13-01", "2026-1-1", "", None, "2026-11-19/../x"):
            with self.assertRaises(ValueError, msg=repr(bad)):
                store.parse_day(bad)

    def test_csv_has_bom_header_and_labels(self):
        text = store.to_csv([
            {"t": 1000, "kind": "fault", "level": "stop", "no": 71, "name": "上内胆2", "ip": "1.1.1.1", "code": 917, "text": "停机"},
            {"t": 1001, "kind": "command", "ok": False, "no": 71, "name": "上内胆2", "ip": "1.1.1.1", "text": "复位", "detail": "超时", "client": "10.0.0.2"},
        ])
        self.assertTrue(text.startswith("﻿时间,类型"))
        self.assertIn("停机", text)
        self.assertIn("失败；超时；来自 10.0.0.2", text)

    def test_csv_labels_mode_switch_and_marks_test_entries(self):
        text = store.to_csv([
            {"t": 1000, "kind": "mode", "ok": True, "text": "切换到测试模式", "detail": "状态改为虚拟模拟数据", "client": "10.0.0.2", "test": True},
            {"t": 1001, "kind": "fault", "level": "stop", "no": 71, "name": "上内胆2", "ip": "1.1.1.1", "code": 917, "text": "停机", "test": True},
            {"t": 1002, "kind": "fault", "level": "stop", "no": 71, "name": "上内胆2", "ip": "1.1.1.1", "code": 917, "text": "停机"},
        ])
        self.assertEqual(store.entry_label({"kind": "mode"}), "模式切换")
        self.assertIn("模式切换", text)
        self.assertEqual(text.count("[测试模式]"), 2)

    def test_message_add_validates_and_persists(self):
        m = self.msgs.add(" 张三 ", " 注意 71 号臂 ", station="71")
        self.assertEqual((m["author"], m["text"], m["id"]), ("张三", "注意 71 号臂", 1))
        self.assertEqual(store.MessageStore(self.dir / "messages.json").list()[0]["text"], "注意 71 号臂")
        for author, text in (("", "x"), ("a", ""), ("a", "x" * 501), ("x" * 21, "x"), (None, "x"), ("a", 5)):
            with self.assertRaises(ValueError, msg=(author, text)):
                self.msgs.add(author, text)

    def test_messages_newest_first_and_ids_not_reused(self):
        a = self.msgs.add("甲", "一")
        b = self.msgs.add("乙", "二")
        self.assertEqual([m["id"] for m in self.msgs.list()], [b["id"], a["id"]])
        self.assertTrue(self.msgs.delete(b["id"]))
        self.assertFalse(self.msgs.delete(b["id"]))
        self.assertEqual(self.msgs.add("丙", "三")["id"], 3)

    def test_failed_save_leaves_memory_unchanged(self):
        self.msgs.add("甲", "一")
        with mock.patch.object(self.msgs, "_save", side_effect=OSError("磁盘已满")):
            with self.assertRaises(OSError):
                self.msgs.add("乙", "二")
            with self.assertRaises(OSError):
                self.msgs.delete(1)
        self.assertEqual([m["text"] for m in self.msgs.list()], ["一"])

    def test_message_cap(self):
        for i in range(store.MessageStore.MAX_KEEP + 5):
            self.msgs.add("甲", str(i))
        self.assertEqual(len(self.msgs.list()), store.MessageStore.MAX_KEEP)

    def test_corrupt_message_file_is_backed_up(self):
        path = self.dir / "messages.json"
        path.write_text("{坏", encoding="utf-8")
        msgs = store.MessageStore(path)
        self.assertEqual(msgs.list(), [])
        self.assertTrue(list(self.dir.glob("messages.json.corrupt-*")))


class CodesTest(unittest.TestCase):
    def test_levels_follow_table(self):
        self.assertEqual(CODES.level_of(None), "offline")
        self.assertEqual(CODES.level_of(204), "ok")
        self.assertEqual(CODES.level_of(816), "warn")
        self.assertEqual(CODES.level_of(917), "stop")
        self.assertEqual(CODES.level_of(183), "unknown")
        self.assertEqual(CODES.level_of(4242), "unknown")


class AppCase(unittest.TestCase):
    """用临时目录和模拟模式搭一个完整 App。"""

    mode = "sim"
    extra = {}

    def make_app(self, stations=None, **over):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        raw = {"mode": self.mode, "stations": stations or [station(71, type="上料臂"), station(73, "192.168.5.73", type="上料臂")], **self.extra, **over}
        cfg = config.validate(raw)
        data = Path(tmp.name)
        host = server.HostInfo([])
        app = server.App(cfg, CODES, store.LogStore(data / "logs"), store.MessageStore(data / "m.json"), host)
        app.monitor.sim = Sim(app.monitor, CODES)
        return app


class MonitorTest(AppCase):
    def setUp(self):
        self.app = self.make_app()
        self.mon = self.app.monitor
        self.st = self.mon.stations["71"]

    def logs(self):
        return self.app.logs.read(store.day_of(time.time()))

    def test_same_code_is_not_a_new_event(self):
        self.mon.record(self.st, 204, 1.0)
        self.mon.record(self.st, 204, 2.0)
        self.assertEqual(len(self.mon.events), 1)
        self.assertEqual((self.st["since"], self.st["lastSeen"]), (1.0, 2.0))

    def test_normal_steps_do_not_alert_or_log(self):
        self.mon.record(self.st, 180, time.time())
        self.mon.record(self.st, 181, time.time())
        self.assertEqual((len(self.mon.alerts), self.logs()), (0, []))

    def test_fault_and_recovery_are_logged_with_duration(self):
        now = time.time()
        self.mon.record(self.st, 204, now)
        self.mon.record(self.st, 917, now + 1)
        self.mon.record(self.st, 100, now + 31)
        self.assertEqual([e["level"] for e in self.mon.alerts], ["stop", "ok"])
        stop, recover = self.logs()
        self.assertEqual((stop["kind"], stop["code"], stop["no"]), ("fault", 917, 71))
        self.assertEqual((recover["kind"], recover["prevSec"]), ("recover", 30))

    def test_fault_register_alerts_use_fault_duration(self):
        """动作码不变时，4101 的故障不能被时间线当成恢复，时长只算故障本身。"""
        now = time.time()
        self.mon.record(self.st, 204, now, action=204, fault=0)
        self.mon.record(self.st, 204, now + 5, action=204, fault=917)
        row = next(s for s in self.mon.snapshot()["stations"] if s["id"] == "71")
        self.assertEqual((row["level"], row["action"], row["fault"]), ("stop", 204, 917))
        self.mon.record(self.st, 204, now + 12, action=204, fault=0)
        self.assertEqual([e["level"] for e in self.mon.alerts], ["stop", "ok"])
        self.assertEqual(self.mon.alerts[0]["code"], 917)
        self.assertEqual((self.mon.alerts[1]["code"], self.mon.alerts[1]["from"]), (204, 917))
        fault, recover = self.logs()[-2:]
        self.assertEqual((fault["kind"], fault["code"], fault["level"]), ("fault", 917, "stop"))
        self.assertEqual(recover["kind"], "recover")
        self.assertEqual(recover["prevSec"], 7.0)
        self.assertIn("917", recover["detail"])
        cleared = next(s for s in self.mon.snapshot()["stations"] if s["id"] == "71")
        self.assertEqual(cleared["level"], "ok")

    def test_warn_fault_paints_card_without_hiding_action(self):
        now = time.time()
        self.mon.record(self.st, 204, now, action=204, fault=0)
        self.mon.record(self.st, 204, now + 1, action=204, fault=816)
        row = next(s for s in self.mon.snapshot()["stations"] if s["id"] == "71")
        self.assertEqual(row["level"], "warn")
        self.assertEqual(row["action"], 204)
        self.assertEqual(self.mon.alerts[-1]["level"], "warn")

    def test_offline_clears_latched_contacts(self):
        self.st["stopped"] = True
        self.st["paused"] = True
        self.st["alarmed"] = True
        self.st["running"] = True
        self.mon.record(self.st, 204, time.time(), action=204, fault=0)
        with self.mon.lock:
            self.mon._mark_offline(self.st, time.time())
        self.assertEqual(
            (self.st["code"], self.st["stopped"], self.st["paused"], self.st["alarmed"], self.st["running"]),
            (None, False, False, False, None),
        )
        self.assertEqual(self.mon._display_level(self.st), "offline")

    def test_first_reading_offline_is_logged(self):
        self.mon.record(self.st, None, time.time())
        self.assertEqual([e["level"] for e in self.logs()], ["offline"])

    def test_first_reading_ok_is_not_a_recovery(self):
        self.mon.record(self.st, 204, time.time())
        self.assertEqual(self.logs(), [])

    def test_offline_then_online_logs_both(self):
        now = time.time()
        self.mon.record(self.st, 204, now)
        self.mon.record(self.st, None, now + 1)
        self.mon.record(self.st, 204, now + 2)
        self.assertEqual([e["kind"] for e in self.logs()], ["fault", "recover"])

    def test_sim_command_logs_operator_action(self):
        r = self.mon.send_command("71", "reset", "10.0.0.5")
        self.assertTrue(r["ok"])
        self.assertEqual(self.st["code"], 100)
        entry = self.logs()[-1]
        self.assertEqual((entry["kind"], entry["command"], entry["client"], entry["ok"]), ("command", "reset", "10.0.0.5", True))

    def test_sim_stop_pauses_and_start_resumes(self):
        self.mon.send_command("71", "stop", "x")
        self.assertTrue(self.st["paused"])
        self.mon.send_command("71", "start", "x")
        self.assertFalse(self.st["paused"])

    def test_invalid_command_and_unknown_station(self):
        with self.assertRaises(ValueError):
            self.mon.send_command("71", "explode", "x")
        with self.assertRaises(KeyError):
            self.mon.send_command("999", "reset", "x")

    def test_snapshot_shape(self):
        snap = self.mon.snapshot()
        self.assertEqual(len(snap["stations"]), 2)
        self.assertEqual(snap["stations"][0]["port"], 502)
        self.assertIn("host", snap)
        self.assertTrue(snap["canControl"])
        self.assertFalse(snap["pinRequired"])


class ModbusCommandTest(AppCase):
    mode = "modbus"

    def make_with_fake(self, command_mode="dobot", command_register=None, **fake_kw):
        fake = FakeModbus(**fake_kw)
        self.addCleanup(fake.close)
        mb = {
            "command_mode": command_mode,
            "coil_pulse_ms": 1,
            "coil_gap_ms": 1,
            "disable_settle_ms": 1,
            "enable_settle_ms": 1,
            "enable_poll_ms": 50,
            "enable_timeout_ms": 2000,
        }
        if command_register is not None:
            mb["command_register"] = command_register
        app = self.make_app([station(1, "127.0.0.1", fake.port)], modbus=mb)
        return app, fake

    def test_read_discrete_enable_status(self):
        fake = FakeModbus(enabled=True)
        self.addCleanup(fake.close)
        self.assertTrue(modbus.read_discrete("127.0.0.1", fake.port, 1, 7, 1.0))
        fake.enabled = False
        self.assertFalse(modbus.read_discrete("127.0.0.1", fake.port, 1, 7, 1.0))

    def test_dobot_start_pulses_start_coil(self):
        app, fake = self.make_with_fake()
        r = app.monitor.send_command("1", "start", "c")
        self.assertTrue(r["ok"])
        self.assertEqual(fake.coils, [(0, modbus.COIL_OFF), (0, modbus.COIL_ON), (0, modbus.COIL_OFF)])
        self.assertTrue(app.monitor.snapshot()["canControl"])

    def test_dobot_reset_clear_disable_enable(self):
        app, fake = self.make_with_fake()
        r = app.monitor.send_command("1", "reset", "c")
        self.assertTrue(r["ok"])
        self.assertIn("清除报警", r["detail"])
        addrs = [c[0] for c in fake.coils]
        # 每步脉冲 3 次写：清报警(5) → 下使能(4) → 上使能(3)
        self.assertEqual(addrs, [5, 5, 5, 4, 4, 4, 3, 3, 3])

    def test_register_mode_writes_holding(self):
        app, fake = self.make_with_fake(command_mode="register", command_register=3900)
        r = app.monitor.send_command("1", "start", "c")
        self.assertTrue(r["ok"])
        self.assertEqual(fake.writes, [(3900, 2)])

    def test_command_to_dead_device_fails_and_is_logged(self):
        app, fake = self.make_with_fake()
        fake.close()
        r = app.monitor.send_command("1", "reset", "c")
        self.assertFalse(r["ok"])
        self.assertIn("失败", r["detail"])

    def test_commands_to_same_station_do_not_interleave(self):
        app, _ = self.make_with_fake()
        order = []

        def slow_pulse(*args, **kwargs):
            order.append("begin")
            time.sleep(0.05)
            order.append("end")

        with mock.patch.object(modbus, "pulse_coil", slow_pulse):
            threads = [threading.Thread(target=app.monitor.send_command, args=("1", cmd, "c"))
                       for cmd in ("start", "stop")]
            for t in threads:
                t.start()
            for t in threads:
                t.join()
        self.assertEqual(order, ["begin", "end", "begin", "end"])

    def test_coil_write_does_not_hold_global_lock(self):
        app, _ = self.make_with_fake()
        held = []

        def fake_pulse(*args, **kwargs):
            acquired = app.monitor.lock.acquire(blocking=False)
            held.append(not acquired)
            if acquired:
                app.monitor.lock.release()

        with mock.patch.object(modbus, "pulse_coil", fake_pulse):
            self.assertTrue(app.monitor.send_command("1", "start", "c")["ok"])
        self.assertEqual(held, [False])

    def test_poll_loop_survives_unexpected_error(self):
        app, _ = self.make_with_fake()
        mon = app.monitor
        mon.cfg["poll_interval"] = 0.02
        calls = []

        def flaky(*args):
            calls.append(1)
            if len(calls) == 1:
                raise RuntimeError("意外错误")
            return 100

        with mock.patch.object(modbus, "read_register", flaky), self.assertLogs("monitor", "ERROR"):
            threading.Thread(target=mon.poll_loop, args=("1",), daemon=True).start()
            deadline = time.time() + 3
            while mon.stations["1"]["code"] != 100 and time.time() < deadline:
                time.sleep(0.02)
        self.assertEqual(mon.stations["1"]["code"], 100)

    def test_poll_marks_offline_after_failures_then_recovers(self):
        app, fake = self.make_with_fake(mode="close")
        mon, st = app.monitor, app.monitor.stations["1"]
        mon.cfg["modbus"]["offline_after_failures"] = 1
        mon.cfg["poll_interval"] = 0.05
        threading.Thread(target=mon.poll_loop, args=("1",), daemon=True).start()
        deadline = time.time() + 3
        while st["code"] is not None and time.time() < deadline or not st["known"]:
            time.sleep(0.05)
            if time.time() > deadline:
                break
        self.assertTrue(st["known"])
        self.assertIsNone(st["code"])


class SimTest(AppCase):
    def test_tick_only_records_valid_codes_and_never_crashes_for_unknown_type(self):
        app = self.make_app([station(1, type="未知工位"), station(2, "192.168.5.2", type="灌装")])
        sim = Sim(app.monitor, CODES)
        with app.monitor.lock:
            for i in range(300):
                sim.tick(1000.0 + i)
        for st in app.monitor.stations.values():
            self.assertIn(CODES.level_of(st["code"]), {"ok", "warn", "stop", "offline"})


class HttpBase(AppCase):
    def setUp(self):
        self.app = self.make_app(control_pin="1234")
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.make_handler(self.app))
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)
        self.base = "http://127.0.0.1:%d" % self.httpd.server_address[1]

    def call(self, method, path, body=None, headers=None, raw=None):
        data = raw if raw is not None else (None if body is None else json.dumps(body).encode())
        h = {"Content-Type": "application/json", **(headers or {})}
        req = urllib.request.Request(self.base + path, data=data, method=method, headers=h)
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, r.read(), r.headers
        except urllib.error.HTTPError as e:
            return e.code, e.read(), e.headers

    def json(self, *a, **kw):
        status, body, _ = self.call(*a, **kw)
        return status, json.loads(body)


class HttpTest(HttpBase):
    def test_state_includes_host_and_stations(self):
        status, data = self.json("GET", "/api/state")
        self.assertEqual(status, 200)
        self.assertTrue(data["pinRequired"])
        self.assertEqual([s["no"] for s in data["stations"]], [71, 73])

    def test_static_index_is_served(self):
        status, body, _ = self.call("GET", "/")
        self.assertEqual(status, 200)
        self.assertIn(b"<html", body)

    def test_command_requires_pin(self):
        status, data = self.json("POST", "/api/command", {"id": "71", "command": "reset"})
        self.assertEqual(status, 403)
        status, data = self.json("POST", "/api/command", {"id": "71", "command": "reset", "pin": "0000"})
        self.assertEqual(status, 403)
        status, data = self.json("POST", "/api/command", {"id": "71", "command": "reset", "pin": "1234"})
        self.assertEqual((status, data["ok"]), (200, True))

    def test_command_validation(self):
        self.assertEqual(self.json("POST", "/api/command", {"id": "71", "command": "boom", "pin": "1234"})[0], 400)
        self.assertEqual(self.json("POST", "/api/command", {"id": "999", "command": "reset", "pin": "1234"})[0], 404)

    def test_pin_with_non_ascii_does_not_crash(self):
        status, _ = self.json("POST", "/api/command", {"id": "71", "command": "reset", "pin": "密码"})
        self.assertEqual(status, 403)

    def test_post_requires_json_content_type(self):
        status, _ = self.json("POST", "/api/report", {"id": "71", "code": 1}, headers={"Content-Type": "text/plain"})
        self.assertEqual(status, 415)

    def go_live(self):
        self.app.monitor.mode = "report"  # 只改标记，不启动轮询线程

    def test_report_ignored_in_test_mode(self):
        self.assertEqual(self.json("POST", "/api/report", {"id": "71", "code": 917})[0], 409)

    def test_report_validation(self):
        self.go_live()
        self.assertEqual(self.json("POST", "/api/report", {"id": "71", "code": 917})[0], 200)
        self.assertEqual(self.json("POST", "/api/report", {"id": "999", "code": 1})[0], 404)
        self.assertEqual(self.json("POST", "/api/report", {"id": "71"})[0], 400)
        self.assertEqual(self.json("POST", "/api/report", raw=b"not json")[0], 400)
        self.assertEqual(self.json("POST", "/api/report", raw=b"[1]")[0], 400)

    def test_fault_report_appears_in_logs_and_csv(self):
        self.go_live()
        self.json("POST", "/api/report", {"id": "71", "code": 917})
        status, data = self.json("GET", "/api/logs")
        self.assertEqual(status, 200)
        self.assertEqual(data["entries"][0]["code"], 917)
        self.assertEqual(self.json("GET", "/api/logs?kind=command")[1]["entries"], [])
        status, body, headers = self.call("GET", "/api/logs.csv")
        self.assertEqual(status, 200)
        self.assertIn("attachment", headers["Content-Disposition"])
        self.assertIn("917", body.decode("utf-8-sig"))

    def test_logs_reject_bad_params(self):
        self.assertEqual(self.json("GET", "/api/logs?date=../../config")[0], 400)
        self.assertEqual(self.json("GET", "/api/logs?kind=bogus")[0], 400)

    def test_message_flow(self):
        status, data = self.json("POST", "/api/messages", {"author": "张三", "text": "71 号臂夹爪松动", "station": "71"})
        self.assertEqual(status, 200)
        mid = data["message"]["id"]
        self.assertEqual(self.json("GET", "/api/messages")[1]["messages"][0]["text"], "71 号臂夹爪松动")
        self.assertEqual(self.json("DELETE", "/api/messages/%d" % mid)[0], 403)
        self.assertEqual(self.json("DELETE", "/api/messages/%d" % mid, headers={"X-Control-Pin": "1234"})[0], 200)
        self.assertEqual(self.json("DELETE", "/api/messages/%d" % mid, headers={"X-Control-Pin": "1234"})[0], 404)

    def test_message_validation(self):
        self.assertEqual(self.json("POST", "/api/messages", {"author": "", "text": "x"})[0], 400)
        self.assertEqual(self.json("POST", "/api/messages", {"author": "a", "text": "x", "station": "999"})[0], 400)
        self.assertEqual(self.json("DELETE", "/api/messages/abc", headers={"X-Control-Pin": "1234"})[0], 400)

    def test_unknown_api_is_404(self):
        self.assertEqual(self.json("GET", "/api/nope")[0], 404)

    def test_oversized_body_rejected(self):
        status, _ = self.json("POST", "/api/report", raw=b"x" * (server.MAX_BODY + 1))
        self.assertEqual(status, 413)

    def test_negative_content_length_rejected(self):
        with socket.create_connection(("127.0.0.1", self.httpd.server_address[1]), timeout=5) as s:
            s.sendall(b"POST /api/report HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
                      b"Content-Length: -1\r\nConnection: close\r\n\r\n")
            reply = s.recv(4096)
        self.assertTrue(reply.startswith(b"HTTP/1.0 400") or reply.startswith(b"HTTP/1.1 400"), reply[:40])

    def test_handler_has_request_timeout(self):
        self.assertEqual(server.make_handler(self.app).timeout, server.REQUEST_TIMEOUT)

    def test_report_rejects_out_of_range_codes(self):
        self.go_live()
        for code in (-1, 65536, 10 ** 400, "abc", [1], float("inf")):
            raw = json.dumps({"id": "71", "code": code}).replace("Infinity", "1e999").encode()
            if code == 10 ** 400:
                raw = b'{"id": "71", "code": 1' + b"0" * 400 + b"}"
            self.assertEqual(self.json("POST", "/api/report", raw=raw)[0], 400, code)
        self.assertEqual(self.json("POST", "/api/report", {"id": "71", "code": None})[0], 200)


class QuietSim(Sim):
    """不产生任何随机状态，让测试结果可预期。"""

    def tick(self, now):
        pass


class ModeSwitchTest(AppCase):
    """测试模式 ⇄ 真实模式的运行时切换；真实模式用 report，避免真的去连设备。"""
    mode = "report"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "mode.json"
        self.app = self.make_app(mode_path=self.path)
        self.mon = self.app.monitor
        self.mon.sim_factory = lambda mon: QuietSim(mon, CODES)

    def make_app(self, mode_path=None, **over):
        app = super().make_app(**over)
        if mode_path is not None:
            app.monitor = Monitor(app.cfg, CODES, app.logs, server.HostInfo([]), mode_path)
        return app

    def test_starts_in_configured_mode(self):
        self.assertEqual(self.mon.mode, "report")
        self.assertFalse(self.mon.snapshot()["test"])

    def test_switch_to_test_resets_state_and_logs_it(self):
        with self.mon.lock:
            self.mon.record(self.mon.stations["71"], 917, time.time())
        result = self.mon.set_mode(True, "10.0.0.9")
        self.assertEqual(result, {"mode": "sim", "changed": True})
        snap = self.mon.snapshot()
        self.assertTrue(snap["test"])
        self.assertNotIn(917, [e["code"] for e in snap["alerts"]])  # 真实模式的旧提醒已清空
        kinds = [e["kind"] for e in self.app.logs.read(store.day_of(time.time()))]
        self.assertEqual(kinds[:2], ["fault", "mode"])

    def test_switch_is_idempotent(self):
        self.assertFalse(self.mon.set_mode(False, "x")["changed"])

    def test_test_mode_entries_are_marked_and_real_ones_are_not(self):
        self.mon.set_mode(True, "x")
        with self.mon.lock:
            self.mon.record(self.mon.stations["71"], 917, time.time())
        self.mon.set_mode(False, "x")
        with self.mon.lock:
            self.mon.record(self.mon.stations["71"], 917, time.time())
        faults = [e for e in self.app.logs.read(store.day_of(time.time())) if e["kind"] == "fault"]
        self.assertEqual([e.get("test", False) for e in faults], [True, False])

    def test_old_sim_thread_stops_after_switch(self):
        self.mon.cfg["poll_interval"] = 0.01
        self.mon.set_mode(True, "x")
        sim = self.mon.sim
        self.mon.set_mode(False, "x")
        time.sleep(0.1)
        with self.mon.lock:
            frozen = [s["code"] for s in self.mon.stations.values()]
        time.sleep(0.1)
        self.assertEqual(frozen, [None, None])
        self.assertIsNot(self.mon.sim, sim)

    def test_choice_survives_restart_only_for_same_config_mode(self):
        self.mon.set_mode(True, "x")
        again = Monitor(self.app.cfg, CODES, self.app.logs, server.HostInfo([]), self.path)
        self.assertEqual(again.mode, "sim")
        changed = Monitor({**self.app.cfg, "mode": "modbus"}, CODES, self.app.logs, server.HostInfo([]), self.path)
        self.assertEqual(changed.mode, "modbus")

    def test_broken_mode_file_is_ignored(self):
        self.path.write_text("{not json", encoding="utf-8")
        self.assertEqual(Monitor(self.app.cfg, CODES, self.app.logs, server.HostInfo([]), self.path).mode, "report")

    def test_commands_in_test_mode_are_marked_test(self):
        self.mon.set_mode(True, "x")
        self.mon.send_command("71", "reset", "x")
        entry = [e for e in self.app.logs.read(store.day_of(time.time())) if e["kind"] == "command"][0]
        self.assertTrue(entry["test"])

    def test_live_mode_of_sim_config_is_modbus(self):
        app = self.make_app(mode="sim")
        self.assertEqual(app.monitor.live_mode, "modbus")


class ModeHttpTest(HttpBase):
    mode = "report"

    def test_mode_endpoint_requires_pin_and_boolean(self):
        self.assertEqual(self.json("POST", "/api/mode", {"test": True})[0], 403)
        self.assertEqual(self.json("POST", "/api/mode", {"test": "yes", "pin": "1234"})[0], 400)
        status, data = self.json("POST", "/api/mode", {"test": True, "pin": "1234"})
        self.assertEqual((status, data["mode"]), (200, "sim"))
        self.assertTrue(self.json("GET", "/api/state")[1]["test"])
        status, data = self.json("POST", "/api/mode", {"test": False, "pin": "1234"})
        self.assertEqual((status, data["mode"]), (200, "report"))

    def test_mode_switch_is_filterable_in_logs(self):
        self.json("POST", "/api/mode", {"test": True, "pin": "1234"})
        status, data = self.json("GET", "/api/logs?kind=mode")
        self.assertEqual(status, 200)
        rows = data["entries"]
        self.assertEqual([e["kind"] for e in rows], ["mode"])
        self.assertTrue(rows[0]["test"])


class HostProbeTest(unittest.TestCase):
    def test_prefers_address_on_station_subnet(self):
        pick = hostinfo.pick_primary(["10.1.33.182", "192.168.5.20"], ["10.1.33.182"], ["192.168.5.71"])
        self.assertEqual(pick, ("192.168.5.20", True))

    def test_falls_back_to_routed_then_any_then_link_local(self):
        self.assertEqual(hostinfo.pick_primary(["10.0.0.2", "10.0.0.3"], ["10.0.0.3"], ["192.168.5.71"]), ("10.0.0.3", False))
        self.assertEqual(hostinfo.pick_primary(["10.0.0.9"], [], ["192.168.5.71"]), ("10.0.0.9", False))
        self.assertEqual(hostinfo.pick_primary(["169.254.3.4"], [], []), ("169.254.3.4", False))
        self.assertEqual(hostinfo.pick_primary(["127.0.0.1", "0.0.0.0"], [], []), (None, False))

    def test_request_address_is_used_when_every_other_source_fails(self):
        with mock.patch.object(hostinfo, "_route_ip", return_value=None),                 mock.patch.object(hostinfo, "_from_hostname", return_value=set()),                 mock.patch.object(hostinfo, "_from_system_tool", return_value=set()):
            host = hostinfo.HostInfo(["192.168.5.71"])
            self.assertIsNone(host.get()["primary"])
            host.note_request_ip("192.168.5.20")
            self.assertEqual(host.get()["primary"], "192.168.5.20")

    def test_failed_probe_is_retried_soon_not_cached_for_full_ttl(self):
        calls = []
        def fake():
            calls.append(1)
            return {"primary": None, "ips": [], "matched": False}
        host = hostinfo.HostInfo([], ttl=30)
        host._probe = fake
        host.get(); host.get()
        self.assertEqual(len(calls), 1)
        host._at -= hostinfo.RETRY_TTL + 0.1
        host.get()
        self.assertEqual(len(calls), 2)

    def test_loopback_request_address_is_ignored(self):
        host = hostinfo.HostInfo([])
        host.note_request_ip("127.0.0.1")
        self.assertNotIn("127.0.0.1", host._seen)


class HostInfoTest(unittest.TestCase):
    def test_returns_ip_list_and_caches(self):
        host = server.HostInfo(["127.0.0.1"], ttl=60)
        first = host.get()
        self.assertIn("primary", first)
        self.assertIs(host.get(), first)
        for ip in first["ips"]:
            self.assertFalse(ip.startswith("127."))


if __name__ == "__main__":
    unittest.main()
