"""校验工程目录里动作/异常映射与监控寄存器约定。"""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent
ENGINE = ROOT / "工程" / "上卡圈02_192.168.5.80"
CODES = ROOT / "codes.json"


def _table(text, name):
    block = re.search(rf"{name}\s*=\s*\{{(.*?)\n\}}", text, re.S)
    assert block, f"找不到 {name}"
    return re.findall(r"\[\s*'([^']+)'\s*\]\s*=\s*(\d+)", block.group(1))


class RobotStatusMapTest(unittest.TestCase):
    def test_action_and_fault_regs_match_config(self):
        glo = (ENGINE / "global.lua").read_text(encoding="utf-8")
        action = re.search(r"HREG_ACTION\s*=\s*(\d+)", glo)
        fault = re.search(r"HREG_FAULT\s*=\s*(\d+)", glo)
        self.assertIsNotNone(action)
        self.assertIsNotNone(fault)
        cfg = json.loads((ROOT / "config.json").read_text(encoding="utf-8"))
        self.assertEqual(int(action.group(1)), cfg["modbus"]["action_register"])
        self.assertEqual(int(fault.group(1)), cfg["modbus"]["fault_register"])
        self.assertNotEqual(cfg["modbus"]["action_register"], cfg["modbus"]["fault_register"])
        self.assertTrue(any(s.get("ip") == "192.168.5.80" for s in cfg["stations"])
                        or (ROOT / "configs").exists())

    def test_stage_action_codes_are_process_codes(self):
        text = (ENGINE / "global.lua").read_text(encoding="utf-8")
        pairs = _table(text, "STAGE_ACTION")
        self.assertGreaterEqual(len(pairs), 10)
        codes = json.loads(CODES.read_text(encoding="utf-8"))["codes"]
        missing = [(n, c) for n, c in pairs if c not in codes]
        self.assertEqual(missing, [])
        for name, code in pairs:
            self.assertLess(int(code), 800, f"动作表不应含异常码: {name}={code}")

    def test_stage_fault_codes_are_exception_codes(self):
        text = (ENGINE / "global.lua").read_text(encoding="utf-8")
        pairs = _table(text, "STAGE_FAULT")
        codes = json.loads(CODES.read_text(encoding="utf-8"))["codes"]
        for name, code in pairs:
            self.assertIn(code, codes)
            self.assertGreaterEqual(int(code), 800, f"异常表应是 8xx/9xx: {name}={code}")


if __name__ == "__main__":
    unittest.main()
