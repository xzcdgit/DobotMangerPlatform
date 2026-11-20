"""持久化：按天分文件的异常/停机/操作日志，以及留言。"""
import csv
import io
import json
import logging
import os
import re
import threading
import time
from pathlib import Path

log = logging.getLogger("monitor.store")

DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
LEVEL_LABEL = {"stop": "停机", "warn": "过程异常", "offline": "离线", "unknown": "未知码", "ok": "运行"}
CSV_HEADER = ["时间", "类型", "序号", "站名", "IP", "状态码", "说明", "上一状态持续(秒)", "备注"]


def day_of(t):
    return time.strftime("%Y-%m-%d", time.localtime(t))


def parse_day(text):
    """校验日期参数；同时挡住路径穿越。"""
    if not isinstance(text, str) or not DAY_RE.match(text):
        raise ValueError("日期格式应为 YYYY-MM-DD")
    time.strptime(text, "%Y-%m-%d")
    return text


def entry_label(entry):
    if entry["kind"] == "command":
        return "操作"
    if entry["kind"] == "recover":
        return "恢复"
    if entry["kind"] == "mode":
        return "模式切换"
    return LEVEL_LABEL.get(entry.get("level"), "异常")


def to_csv(entries):
    """带 BOM 的 UTF-8 CSV，Excel 直接打开不乱码。"""
    out = io.StringIO()
    w = csv.writer(out)
    w.writerow(CSV_HEADER)
    for e in entries:
        stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(e["t"]))
        remark = e.get("detail", "")
        if e["kind"] == "command":
            remark = "%s；%s；来自 %s" % ("成功" if e.get("ok") else "失败", e.get("detail", ""), e.get("client", ""))
        if e.get("test"):
            remark = "[测试模式] " + remark
        w.writerow([stamp, entry_label(e), e.get("no", ""), e.get("name", ""), e.get("ip", ""),
                    e.get("code") if e.get("code") is not None else "", e.get("text", ""),
                    e.get("prevSec", ""), remark])
    return "﻿" + out.getvalue()


class LogStore:
    """每天一个 JSONL 文件：logs/2026-11-19.jsonl。"""

    def __init__(self, directory):
        self.dir = Path(directory)
        self.lock = threading.Lock()

    def append(self, entry):
        path = self.dir / (day_of(entry["t"]) + ".jsonl")
        line = json.dumps(entry, ensure_ascii=False) + "\n"
        try:
            with self.lock:
                self.dir.mkdir(parents=True, exist_ok=True)
                with path.open("a", encoding="utf-8") as f:
                    f.write(line)
        except OSError:
            log.exception("写日志失败：%s", path)

    def dates(self):
        if not self.dir.is_dir():
            return []
        return sorted((p.stem for p in self.dir.glob("*.jsonl") if DAY_RE.match(p.stem)), reverse=True)

    def read(self, day, limit=5000):
        path = self.dir / (parse_day(day) + ".jsonl")
        entries = []
        with self.lock:
            if not path.exists():
                return entries
            with path.open(encoding="utf-8") as f:
                for n, line in enumerate(f, start=1):
                    if not line.strip():
                        continue
                    try:
                        entries.append(json.loads(line))
                    except ValueError:
                        log.warning("跳过损坏的日志行：%s 第 %d 行", path.name, n)
        return entries[-limit:]


class MessageStore:
    MAX_KEEP = 500
    MAX_TEXT = 500
    MAX_AUTHOR = 20

    def __init__(self, path):
        self.path = Path(path)
        self.lock = threading.Lock()
        self._items = self._load()
        self._next_id = max((m["id"] for m in self._items), default=0) + 1

    def _load(self):
        if not self.path.exists():
            return []
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            if not isinstance(data, list):
                raise ValueError("顶层不是数组")
            return data
        except (OSError, ValueError):
            backup = self.path.with_name("%s.corrupt-%d" % (self.path.name, int(time.time())))
            log.exception("留言文件损坏，已改名为 %s 并重新开始", backup.name)
            try:
                os.replace(self.path, backup)
            except OSError:
                log.exception("无法备份损坏的留言文件")
            return []

    def _save(self, items):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_name(self.path.name + ".tmp")
        tmp.write_text(json.dumps(items, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, self.path)

    def list(self):
        with self.lock:
            return [dict(m) for m in reversed(self._items)]

    def latest_t(self):
        with self.lock:
            return self._items[-1]["t"] if self._items else 0

    def add(self, author, text, station=None, now=None):
        author = author.strip() if isinstance(author, str) else ""
        text = text.strip() if isinstance(text, str) else ""
        if not 1 <= len(author) <= self.MAX_AUTHOR:
            raise ValueError("请填写姓名（1~%d 个字）" % self.MAX_AUTHOR)
        if not 1 <= len(text) <= self.MAX_TEXT:
            raise ValueError("留言内容需为 1~%d 个字" % self.MAX_TEXT)
        with self.lock:
            msg = {"id": self._next_id,
                   "t": time.time() if now is None else now,
                   "author": author, "text": text, "station": station}
            items = [*self._items, msg][-self.MAX_KEEP:]
            self._save(items)  # 先落盘再提交内存，写盘失败时内存与文件保持一致
            self._items = items
            self._next_id += 1  # 删除后编号也不回收，前端的"新留言"红点靠编号递增判断
            return dict(msg)

    def delete(self, msg_id):
        with self.lock:
            kept = [m for m in self._items if m["id"] != msg_id]
            if len(kept) == len(self._items):
                return False
            self._save(kept)
            self._items = kept
            return True
