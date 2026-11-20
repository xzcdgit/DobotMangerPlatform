"""模拟模式：按工位类型生成典型流程和随机异常，用于演示和联调。"""
import random
import time

SIM_STARTUP = [100, 101, 104, 105, 110, 111, 112, 113, 114]
SIM_FLOWS = {
    "上料臂": [180, 181, 182, 200, 201, 202, 204, 205, 206, 209, 210, 212, 213, 214, 220, 221, 223, 184, 185, 186, 187],
    "托举臂": [400, 401, 402, 404, 405, 406, 407],
    "灌装": [180, 181, 182, 500, 501, 502, 503, 505, 184, 185, 186, 187],
    "开盖": [180, 181, 182, 200, 204, 206, 506, 507, 508, 184, 185, 186, 187],
    "气垫取放": [180, 181, 200, 204, 206, 210, 212, 514, 515, 213, 214, 184, 185, 186, 187],
    "粉扑": [180, 181, 182, 200, 204, 205, 206, 210, 212, 213, 214, 510, 511, 184, 185, 186, 187],
}
GENERIC_FLOW = [180, 181, 182, 184, 185, 186, 187]
RESET_CODE = 100


class Sim:
    def __init__(self, monitor, codes, rnd=None):
        self.monitor = monitor
        self.codes = codes
        self.rnd = rnd or random.Random()
        n = len(SIM_STARTUP)
        self.state = {sid: {"i": self.rnd.randrange(n, n + 8), "hold": 0, "frozen": 0}
                      for sid in monitor.stations}

    def apply(self, station, command, now):
        """执行操作员命令；调用方须持有 monitor.lock。返回写入日志的说明。"""
        st = self.state[station["id"]]
        if command == "stop":
            station["paused"] = True
            return "模拟模式：已脉冲停止线圈"
        if command == "start":
            station["paused"] = False
            return "模拟模式：已脉冲开始线圈"
        st.update(i=0, hold=0, frozen=0)
        station["paused"] = False
        self.monitor.record(station, RESET_CODE, now, action=RESET_CODE, fault=0)
        return "模拟模式：复位完成：清除报警 → 下使能 → 上使能"

    def tick(self, now):
        """推进一步；调用方须持有 monitor.lock。"""
        rnd = self.rnd
        for sid, station in self.monitor.stations.items():
            if station["paused"]:
                continue
            st = self.state[sid]
            seq = SIM_STARTUP + SIM_FLOWS.get(station["type"], GENERIC_FLOW)
            if st["frozen"] > 0:  # 停机锁存或离线，维持到倒计时结束再重新启动
                st["frozen"] -= 1
                if st["frozen"] == 0:
                    st["i"] = 0
                continue
            st["hold"] -= 1
            if st["hold"] > 0:
                continue
            st["hold"] = rnd.randint(1, 3)
            roll = rnd.random()
            pool = self.codes.pool(station["type"])
            if roll < 0.004:
                st["frozen"] = rnd.randint(4, 8)
                self.monitor.record(station, None, now, action=None, fault=None)
                continue
            if roll < 0.010:
                stops = [c for c in pool if 900 <= c < 940]
                if stops:
                    st["frozen"] = rnd.randint(8, 15)
                    fault = rnd.choice(stops)
                    action = station.get("action") or seq[min(st["i"], len(seq) - 1)]
                    self.monitor.record(station, fault, now, action=action, fault=fault)
                    continue
            if roll < 0.060:
                warns = [c for c in pool if 800 <= c < 900]
                if warns:
                    fault = rnd.choice(warns)
                    action = station.get("action") or seq[min(st["i"], len(seq) - 1)]
                    self.monitor.record(station, fault, now, action=action, fault=fault)
                    st["hold"] = rnd.randint(2, 4)
                    continue
            st["i"] += 1
            if st["i"] >= len(seq):
                st["i"] = len(SIM_STARTUP)
            action = seq[st["i"]]
            self.monitor.record(station, action, now, action=action, fault=0)

    def run(self, gen=None):
        gen = self.monitor._gen if gen is None else gen
        while gen == self.monitor._gen:
            with self.monitor.lock:
                if gen != self.monitor._gen:
                    return
                self.tick(time.time())
            time.sleep(self.monitor.cfg["poll_interval"])
