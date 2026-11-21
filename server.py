"""美国线机械臂状态监控：HTTP 服务（仅标准库）。

config.json 的 mode（启动时的运行模式）：
  modbus  真实模式：轮询每个工作站的状态码寄存器（Modbus TCP，功能码 03/04）
  report  真实模式：只接收 POST /api/report {"id": "71", "code": 204}
  sim     测试模式：模拟各工位的典型流程，用于演示和联调
页面右上角的按钮可在测试模式和真实模式之间切换，选择保存在 data/mode.json。
真实模式下接受主动上报；测试模式下忽略上报。
"""
import hmac
import json
import logging
import sys
import threading
import time
import webbrowser
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import config as config_mod
from codes import Codes, CodesError, load as load_codes
from hostinfo import HostInfo
from monitor import Monitor
from sim import Sim
from store import LogStore, MessageStore, day_of, parse_day, to_csv

HERE = Path(__file__).resolve().parent
WEB = HERE / "web"
CODES_PATH = HERE / "codes.json"
MAX_BODY = 8192
REQUEST_TIMEOUT = 10
MAX_CODE = 65535
LOG_KINDS = ("fault", "recover", "command", "mode")
log = logging.getLogger("monitor.http")


class App:
    def __init__(self, cfg, codes, logs, messages, host, mode_path=None, hold_path=None):
        self.cfg = cfg
        self.logs = logs
        self.messages = messages
        self.monitor = Monitor(cfg, codes, logs, host, mode_path, hold_path)

    def pin_ok(self, given):
        pin = self.cfg["control_pin"]
        return not pin or (isinstance(given, str) and hmac.compare_digest(given.encode(), pin.encode()))


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status, self.message = status, message


def make_handler(app):
    class Handler(SimpleHTTPRequestHandler):
        timeout = REQUEST_TIMEOUT  # 防止半开连接长期占用线程

        def __init__(self, *a, **kw):
            super().__init__(*a, directory=str(WEB), **kw)

        def log_message(self, *args):
            pass

        def end_headers(self):
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            super().end_headers()

        def _send(self, body, ctype, status=200, extra=()):
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            for k, v in extra:
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def _json(self, obj, status=200):
            self._send(json.dumps(obj, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8", status)

        def _body(self):
            ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
            if ctype != "application/json":  # 同时挡住跨站表单提交
                raise ApiError(415, "请求头 Content-Type 必须是 application/json")
            try:
                n = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                raise ApiError(400, "Content-Length 不合法") from None
            if n < 0:
                raise ApiError(400, "Content-Length 不合法")
            if n > MAX_BODY:
                raise ApiError(413, "请求内容过大")
            try:
                body = json.loads(self.rfile.read(n) or b"null")
            except ValueError:
                raise ApiError(400, "请求内容不是合法的 JSON") from None
            if not isinstance(body, dict):
                raise ApiError(400, "请求内容必须是 JSON 对象")
            return body

        def _dispatch(self, handlers):
            path = urlsplit(self.path).path
            try:
                handler = handlers.get(path)
                if handler is None and path.startswith("/api/messages/"):
                    handler = handlers.get("/api/messages/<id>")
                if handler is None:
                    raise ApiError(404, "接口不存在")
                handler(path)
            except ApiError as e:
                self._json({"error": e.message}, e.status)
            except Exception:
                log.exception("处理 %s 出错", path)
                self._json({"error": "服务器内部错误，详情见服务器日志"}, 500)

        # ---------- GET ----------
        def do_GET(self):
            path = urlsplit(self.path).path
            if not path.startswith("/api/"):
                return super().do_GET()
            self._dispatch({"/api/state": self._state, "/api/codes": self._codes,
                            "/api/logs": self._logs, "/api/logs.csv": self._logs_csv,
                            "/api/messages": self._messages})

        def _state(self, _):
            app.monitor.host.note_request_ip(self.connection.getsockname()[0])
            self._json(app.monitor.snapshot())

        def _codes(self, _):
            self._json(app.monitor.codes.raw)

        def _query_logs(self):
            q = parse_qs(urlsplit(self.path).query)
            day = (q.get("date") or [day_of(time.time())])[0]
            kind = (q.get("kind") or ["all"])[0]
            try:
                parse_day(day)
            except ValueError as e:
                raise ApiError(400, str(e)) from None
            if kind != "all" and kind not in LOG_KINDS:
                raise ApiError(400, "kind 只能是 all、fault、recover、command、mode")
            entries = [e for e in app.logs.read(day) if kind == "all" or e["kind"] == kind]
            return day, entries

        def _logs(self, _):
            day, entries = self._query_logs()
            self._json({"date": day, "dates": app.logs.dates(), "entries": list(reversed(entries))})

        def _logs_csv(self, _):
            day, entries = self._query_logs()
            self._send(to_csv(entries).encode("utf-8"), "text/csv; charset=utf-8",
                       extra=[("Content-Disposition", 'attachment; filename="monitor-log-%s.csv"' % day)])

        def _messages(self, _):
            self._json({"messages": app.messages.list()})

        # ---------- POST / DELETE ----------
        def do_POST(self):
            self._dispatch({"/api/report": self._report, "/api/command": self._command,
                            "/api/station": self._station,
                            "/api/mode": self._mode, "/api/messages": self._add_message})

        def do_DELETE(self):
            self._dispatch({"/api/messages/<id>": self._delete_message})

        def _report(self, _):
            body = self._body()
            try:
                sid, code = str(body["id"]), body["code"]
                code = None if code is None else int(code)
            except (KeyError, TypeError, ValueError, OverflowError):
                raise ApiError(400, "需要 {id, code}") from None
            if code is not None and not 0 <= code <= MAX_CODE:
                raise ApiError(400, "code 必须在 0~%d 之间，或为 null" % MAX_CODE)
            mon = app.monitor
            with mon.lock:
                if mon.mode == "sim":
                    raise ApiError(409, "当前是测试模式，已忽略上报；切换到真实模式后才接收真实状态")
                st = mon.stations.get(sid)
                if st is None:
                    raise ApiError(404, "未知工作站 " + sid)
                if not st.get("enabled", True):
                    raise ApiError(409, "该工位已冻结，已忽略上报")
                mon.record(st, code, time.time())
            self._json({"ok": True})

        def _command(self, _):
            body = self._body()
            if not app.pin_ok(body.get("pin")):
                raise ApiError(403, "操作密码错误")
            try:
                result = app.monitor.send_command(str(body.get("id", "")), body.get("command"),
                                                  self.client_address[0])
            except KeyError:
                raise ApiError(404, "未知工作站") from None
            except ValueError as e:
                raise ApiError(400, str(e)) from None
            self._json(result)

        def _station(self, _):
            body = self._body()
            if not app.pin_ok(body.get("pin")):
                raise ApiError(403, "操作密码错误")
            if not isinstance(body.get("enabled"), bool):
                raise ApiError(400, "需要 {id, enabled: true 或 false}")
            try:
                result = app.monitor.set_enabled(str(body.get("id", "")), body["enabled"], self.client_address[0])
            except KeyError:
                raise ApiError(404, "未知工作站") from None
            except ValueError as e:
                raise ApiError(400, str(e)) from None
            self._json(result)

        def _mode(self, _):
            body = self._body()
            if not app.pin_ok(body.get("pin")):
                raise ApiError(403, "操作密码错误")
            if not isinstance(body.get("test"), bool):
                raise ApiError(400, "需要 {test: true 或 false}")
            self._json({"ok": True, **app.monitor.set_mode(body["test"], self.client_address[0])})

        def _add_message(self, _):
            body = self._body()
            station = body.get("station")
            if station is not None and str(station) not in app.monitor.stations:
                raise ApiError(400, "留言关联的工作站不存在")
            try:
                msg = app.messages.add(body.get("author"), body.get("text"),
                                       None if station is None else str(station))
            except ValueError as e:
                raise ApiError(400, str(e)) from None
            self._json({"ok": True, "message": msg})

        def _delete_message(self, path):
            if not app.pin_ok(self.headers.get("X-Control-Pin", "")):
                raise ApiError(403, "操作密码错误")
            try:
                msg_id = int(path.rsplit("/", 1)[1])
            except ValueError:
                raise ApiError(400, "留言编号不合法") from None
            if not app.messages.delete(msg_id):
                raise ApiError(404, "留言不存在")
            self._json({"ok": True})

    return Handler


def build_app(config_path=None, codes_path=None, data_dir=None):
    cfg = config_mod.load(config_path or HERE / "config.json")
    table = load_codes(codes_path or CODES_PATH)
    data = Path(data_dir or HERE / "data")
    host = HostInfo(s["ip"] for s in cfg["stations"])
    return App(cfg, Codes(table), LogStore(data / "logs"), MessageStore(data / "messages.json"), host,
               data / "mode.json", data / "holds.json")


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    try:
        app = build_app()
    except (config_mod.ConfigError, CodesError, OSError) as e:
        print("配置文件有误，无法启动：\n  %s" % e, file=sys.stderr)
        sys.exit(1)
    app.monitor.start(lambda mon: Sim(mon, mon.codes))
    port = app.cfg["port"]
    host = app.monitor.host.get()
    url = "http://localhost:%d" % port
    print("机械臂状态监控  模式=%s  工作站=%d 个" % ("测试（虚拟数据）" if app.monitor.mode == "sim" else "真实（%s）" % app.monitor.mode,
                                                  len(app.cfg["stations"])))
    print("本机 IP：%s    浏览器打开 %s（端口来自 config.json 的 port）" % (host["primary"] or "未检测到", url))
    httpd = ThreadingHTTPServer(("0.0.0.0", port), make_handler(app))
    # 稍等监听就绪再开浏览器，端口只认 config.json，不必改 start.bat
    threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    httpd.serve_forever()


if __name__ == "__main__":
    main()
