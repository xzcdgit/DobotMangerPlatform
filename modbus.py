"""最小化的 Modbus TCP 客户端：读寄存器（03/04）、写保持寄存器（06）、写线圈（05）。"""
import socket
import struct
import time

# 写单个线圈：ON=0xFF00，OFF=0x0000（Modbus 规范）
COIL_ON = 0xFF00
COIL_OFF = 0x0000


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise OSError("连接被关闭")
        buf += chunk
    return buf


def read_register(ip, port, slave, reg, rtype, timeout):
    """读 1 个寄存器，返回无符号 16 位整数。"""
    func = 3 if rtype == "holding" else 4
    req = struct.pack(">HHHBBHH", 1, 0, 6, slave, func, reg, 1)
    with socket.create_connection((ip, port), timeout=timeout) as s:
        s.settimeout(timeout)
        s.sendall(req)
        head = recv_exact(s, 9)  # MBAP(7) + 功能码 + 字节数/异常码
        if head[7] & 0x80:
            raise OSError("Modbus 异常码 %d" % head[8])
        if head[8] != 2:
            raise OSError("返回长度异常")
        return struct.unpack(">H", recv_exact(s, 2))[0]


def write_register(ip, port, slave, reg, value, timeout):
    """写 1 个保持寄存器（功能码 06），并校验设备的回显。"""
    req = struct.pack(">HHHBBHH", 1, 0, 6, slave, 6, reg, value)
    with socket.create_connection((ip, port), timeout=timeout) as s:
        s.settimeout(timeout)
        s.sendall(req)
        head = recv_exact(s, 8)  # MBAP(7) + 功能码
        if head[7] & 0x80:
            raise OSError("Modbus 异常码 %d" % recv_exact(s, 1)[0])
        if struct.unpack(">HH", recv_exact(s, 4)) != (reg, value):
            raise OSError("设备回显与写入内容不一致")


def write_coil(ip, port, slave, addr, on, timeout):
    """写 1 个线圈（功能码 05），并校验设备的回显。on 为 True 写 ON，否则写 OFF。"""
    value = COIL_ON if on else COIL_OFF
    req = struct.pack(">HHHBBHH", 1, 0, 6, slave, 5, addr, value)
    with socket.create_connection((ip, port), timeout=timeout) as s:
        s.settimeout(timeout)
        s.sendall(req)
        head = recv_exact(s, 8)  # MBAP(7) + 功能码
        if head[7] & 0x80:
            raise OSError("Modbus 异常码 %d" % recv_exact(s, 1)[0])
        if struct.unpack(">HH", recv_exact(s, 4)) != (addr, value):
            raise OSError("设备回显与写入内容不一致")


def read_discrete(ip, port, slave, addr, timeout):
    """读 1 个离散量/触点（功能码 02），返回 True/False。Dobot map1 使能状态地址为 7。"""
    return read_discretes(ip, port, slave, addr, 1, timeout)[0]


def read_discretes(ip, port, slave, addr, count, timeout):
    """读连续离散量/触点（功能码 02），返回 bool 列表。脚本地址与越疆 map1 触点一致。"""
    if count < 1 or count > 2000:
        raise ValueError("count 超出范围")
    req = struct.pack(">HHHBBHH", 1, 0, 6, slave, 2, addr, count)
    with socket.create_connection((ip, port), timeout=timeout) as s:
        s.settimeout(timeout)
        s.sendall(req)
        head = recv_exact(s, 9)  # MBAP(7) + 功能码 + 字节数/异常码
        if head[7] & 0x80:
            raise OSError("Modbus 异常码 %d" % head[8])
        nbytes = head[8]
        if nbytes < 1:
            raise OSError("返回长度异常")
        data = recv_exact(s, nbytes)
        out = []
        for i in range(count):
            out.append(bool(data[i // 8] & (1 << (i % 8))))
        return out


def pulse_coil(ip, port, slave, addr, timeout, pulse_ms=200):
    """上升沿脉冲：先写 OFF 再写 ON，保持 pulse_ms 后拉回 OFF。

    DobotStudio 远程控制默认按上升沿触发线圈功能（开始/停止/使能/清报警等）。
    """
    write_coil(ip, port, slave, addr, False, timeout)
    write_coil(ip, port, slave, addr, True, timeout)
    time.sleep(max(0, pulse_ms) / 1000.0)
    write_coil(ip, port, slave, addr, False, timeout)
