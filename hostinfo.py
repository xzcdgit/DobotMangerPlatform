"""获取运行本软件的电脑的 IPv4 地址（Modbus TCP 主站地址）。

单一来源在不少电脑上会失效（没有默认网关、主机名解析失败、只有虚拟网卡等），
所以同时用几种来源，再按“和工作站同网段”优先排序。
"""
import ipaddress
import logging
import re
import socket
import subprocess
import sys
import threading
import time

log = logging.getLogger("monitor.host")

IPV4_RE = re.compile(r"(?<![\d.])(\d{1,3}(?:\.\d{1,3}){3})(?![\d.])")
PROBE_FALLBACK = "8.8.8.8"  # 只用于让系统选出默认出口网卡，UDP connect 不会发出任何数据包
RETRY_TTL = 3.0  # 没检测到时尽快重试，不要缓存失败结果


def _valid(ip):
    try:
        return ipaddress.IPv4Address(ip)
    except ValueError:
        return None


def _route_ip(dest):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((dest, 9))
        return s.getsockname()[0]
    except OSError:
        return None
    finally:
        s.close()


def _from_hostname():
    found = set()
    name = socket.gethostname()
    for fn in (lambda: socket.gethostbyname_ex(name)[2],
               lambda: [i[4][0] for i in socket.getaddrinfo(name, None, socket.AF_INET)]):
        try:
            found.update(fn())
        except (OSError, UnicodeError):
            pass
    return found


def _from_system_tool():
    """解析 ipconfig / ip addr 的输出，只取地址，不依赖系统语言。"""
    try:
        if sys.platform == "win32":
            out = subprocess.run(["ipconfig"], capture_output=True, timeout=5,
                                 creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0)).stdout
            text = out.decode("mbcs", errors="replace")
            lines = [ln for ln in text.splitlines() if "IPv4" in ln or "IP Address" in ln]
        else:
            text = subprocess.run(["ip", "-4", "-o", "addr"], capture_output=True, timeout=5).stdout.decode(errors="replace")
            lines = text.splitlines()
    except (OSError, subprocess.SubprocessError):
        return set()
    found = set()
    for ln in lines:
        m = IPV4_RE.search(ln.split("/")[0] if sys.platform != "win32" else ln)
        if m:
            found.add(m.group(1))
    return found


def _classify(ip):
    """返回 (可用, 链路本地)。回环、0.x、组播不可用；169.254 只作最后的备选。"""
    a = _valid(ip)
    if a is None or a.is_loopback or a.is_multicast or a.is_unspecified or ip.startswith("0."):
        return False, False
    return True, a.is_link_local


def _net24(ip):
    return ".".join(ip.split(".")[:3])


def pick_primary(candidates, routed, station_ips):
    """从候选里选出主站 IP。优先：与工作站同网段 > 系统路由选出的 > 任意可用地址 > 链路本地地址。"""
    usable = [ip for ip in candidates if _classify(ip) == (True, False)]
    link_local = [ip for ip in candidates if _classify(ip) == (True, True)]
    nets = [_net24(s) for s in station_ips]
    if usable and nets:
        scored = sorted(usable, key=lambda ip: (-sum(1 for n in nets if n == _net24(ip)), ip not in routed, _key(ip)))
        if _net24(scored[0]) in nets:
            return scored[0], True
    for ip in routed:
        if ip in usable:
            return ip, False
    if usable:
        return sorted(usable, key=_key)[0], False
    if link_local:
        return sorted(link_local, key=_key)[0], False
    return None, False


def _key(ip):
    return socket.inet_aton(ip)


class HostInfo:
    """get() 返回 {primary, ips, matched, source}。

    matched 表示 primary 与至少一个工作站同网段，即这块网卡确实能直连工作站。
    """

    def __init__(self, station_ips, ttl=30.0):
        self.station_ips = list(station_ips)
        self.ttl = ttl
        self._at = float("-inf")
        self._value = {"primary": None, "ips": [], "matched": False}
        self._seen = set()
        self._lock = threading.Lock()

    def note_request_ip(self, ip):
        """浏览器访问本服务时用的本机地址，一定是真实可达的，作为兜底来源。"""
        ok, _ = _classify(ip or "")
        if ok and ip not in self._seen:
            self._seen.add(ip)
            self._at = float("-inf")

    def get(self):
        # 探测可能因 DNS 或 ipconfig 变慢；已有一个线程在探测时，其他请求直接用上一次的结果，不排队等待
        if not self._lock.acquire(blocking=False):
            return self._value
        try:
            now = time.monotonic()
            ttl = self.ttl if self._value["primary"] else min(self.ttl, RETRY_TTL)
            if now - self._at >= ttl:
                self._value = self._probe()
                self._at = now
            return self._value
        finally:
            self._lock.release()

    def _probe(self):
        routed = [ip for ip in (_route_ip(d) for d in [*self.station_ips, PROBE_FALLBACK]) if ip]
        found = {*routed, *self._seen, *_from_hostname(), *_from_system_tool()}
        candidates = [ip for ip in found if _classify(ip)[0]]
        primary, matched = pick_primary(candidates, routed, self.station_ips)
        ips = sorted((ip for ip in candidates if _classify(ip) == (True, False)), key=_key)
        if primary and primary not in ips:
            ips.append(primary)
        if not primary:
            log.warning("未能检测到本机 IPv4 地址")
        return {"primary": primary, "ips": ips, "matched": matched}
