"""打包便携部署版：内置 Windows 嵌入式 Python，目标机无需安装 Python。"""
from __future__ import annotations

import datetime as dt
import hashlib
import shutil
import sys
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUT_DIR = ROOT / "发布"
CACHE_DIR = OUT_DIR / "_cache"
APP_NAME = "机器人可视化平台"

# 官方嵌入式运行时（仅标准库，体积小，免安装）
PYTHON_VER = "3.12.8"
PYTHON_EMBED_URL = (
    f"https://www.python.org/ftp/python/{PYTHON_VER}/python-{PYTHON_VER}-embed-amd64.zip"
)
PYTHON_EMBED_NAME = f"python-{PYTHON_VER}-embed-amd64.zip"

INCLUDE_FILES = [
    "server.py",
    "config.py",
    "config.json",
    "codes.py",
    "hostinfo.py",
    "modbus.py",
    "monitor.py",
    "sim.py",
    "store.py",
    "README.md",
]
INCLUDE_DIRS = ["web", "工程", "configs"]
SKIP_DIR_NAMES = {"__pycache__", ".git", ".cursor", "data", "发布"}
SKIP_FILE_SUFFIXES = {".pyc", ".pyo"}

DEPLOY_TXT = f"""机器人可视化平台 — 便携部署说明
================================

本压缩包已内置 Python {PYTHON_VER}（官方 embed 运行时），目标电脑一般**不必再安装 Python**。

一、环境要求
  - Windows 10/11 64 位
  - 与机器人同一网段（例如 192.168.5.x）
  - 无需 pip、无需管理员安装（解压即用）

二、使用步骤
  1. 解压到任意目录（建议路径短、无特殊权限）
  2. 按现场选用 configs\\ 里对应产线配置，复制覆盖根目录 config.json
     （或直接改 config.json 的 stations / mode / 寄存器）
  3. 双击 start.bat（会按 config.json 的 port 自动打开浏览器）
  4. 其它电脑访问：http://本机IP:端口（端口同 config.json 的 port）

三、目录说明
  start.bat     启动（优先用自带 runtime\\python.exe）
  runtime\\      内置 Python，请勿删除
  config.json   当前生效配置
  configs\\      各产线配置（复制覆盖 config.json 即换线）
  web\\          网页前端
  工程\\         机器人 Lua 备份
  data\\         运行日志/留言（首次自动生成）

四、注意
  - 改配置后需关掉黑窗口再重新 start.bat
  - 若杀毒软件拦截 python.exe / 端口 8080，请加白名单或放行
  - 本包为 64 位；极少数 32 位电脑无法直接使用
"""

START_BAT = r"""@echo off
chcp 65001 >nul
cd /d "%~dp0"
title 机器人可视化平台

set "PY="
if exist "%~dp0runtime\python.exe" (
  set "PY=%~dp0runtime\python.exe"
) else (
  where py >nul 2>nul
  if %errorlevel%==0 set "PY=py -3"
)
if not defined PY (
  where python >nul 2>nul
  if %errorlevel%==0 set "PY=python"
)
if not defined PY (
  echo [错误] 未找到运行时。请确认 runtime\python.exe 存在，或本机已安装 Python。
  pause
  exit /b 1
)

if not exist "data" mkdir data
echo.
echo  机器人可视化平台（便携版）
echo  端口见 config.json 的 port；启动后会自动打开浏览器
echo  关闭本窗口即停止服务
echo.
"%PY%" server.py
echo.
echo 服务已退出。
pause
"""


def copy_tree(src: Path, dst: Path) -> None:
    for item in src.rglob("*"):
        if not item.is_file():
            continue
        rel = item.relative_to(src)
        if any(p in SKIP_DIR_NAMES for p in rel.parts):
            continue
        if item.suffix.lower() in SKIP_FILE_SUFFIXES:
            continue
        target = dst / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(item, target)


def download_embed_zip() -> Path:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    dest = CACHE_DIR / PYTHON_EMBED_NAME
    if dest.exists() and dest.stat().st_size > 1_000_000:
        print("使用缓存:", dest)
        return dest
    print("下载嵌入式 Python:", PYTHON_EMBED_URL)
    tmp = dest.with_suffix(".zip.part")
    try:
        urllib.request.urlretrieve(PYTHON_EMBED_URL, tmp)
        tmp.replace(dest)
    except Exception as e:
        if tmp.exists():
            tmp.unlink()
        raise SystemExit(f"下载失败: {e}\n可手动下载到: {dest}") from e
    print("下载完成:", dest, "bytes=", dest.stat().st_size)
    return dest


def install_runtime(stage: Path, embed_zip: Path) -> Path:
    runtime = stage / "runtime"
    if runtime.exists():
        shutil.rmtree(runtime)
    runtime.mkdir(parents=True)
    with zipfile.ZipFile(embed_zip, "r") as zf:
        zf.extractall(runtime)

    # 嵌入式默认限制路径；加上「应用根目录」才能 import 同目录模块
    pth_files = list(runtime.glob("python*._pth"))
    if not pth_files:
        raise SystemExit("嵌入式包中未找到 python*._pth")
    pth = pth_files[0]
    lines = [
        "python312.zip" if (runtime / "python312.zip").exists() else pth.read_text(encoding="utf-8").splitlines()[0],
        ".",
        "..",
        "#import site",
        "",
    ]
    # 用实际 zip 名
    zips = list(runtime.glob("python*.zip"))
    if zips:
        lines[0] = zips[0].name
    pth.write_text("\n".join(lines), encoding="utf-8")

    exe = runtime / "python.exe"
    if not exe.exists():
        raise SystemExit("runtime/python.exe 缺失")
    return exe


def smoke_test(python_exe: Path, stage: Path) -> None:
    """用内置解释器做一次最小导入检查。"""
    import subprocess

    code = (
        "import sys; from pathlib import Path; "
        "sys.path.insert(0, r'%s'); "
        "import config, server, monitor, modbus; "
        "print('ok', sys.version.split()[0])" % str(stage).replace("\\", "\\\\")
    )
    r = subprocess.run([str(python_exe), "-c", code], cwd=str(stage), capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"内置 Python 冒烟失败:\n{r.stdout}\n{r.stderr}")
    print("冒烟测试:", r.stdout.strip())


def build() -> Path:
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M")
    folder_name = f"{APP_NAME}-便携版-{stamp}"
    stage = OUT_DIR / folder_name
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)

    for name in INCLUDE_FILES:
        src = ROOT / name
        if not src.exists():
            raise SystemExit(f"缺少文件: {name}")
        shutil.copy2(src, stage / name)

    for name in INCLUDE_DIRS:
        src = ROOT / name
        if not src.exists():
            raise SystemExit(f"缺少目录: {name}")
        copy_tree(src, stage / name)

    embed_zip = download_embed_zip()
    python_exe = install_runtime(stage, embed_zip)
    smoke_test(python_exe, stage)

    (stage / "start.bat").write_text(START_BAT, encoding="utf-8-sig")
    (stage / "部署说明.txt").write_text(DEPLOY_TXT, encoding="utf-8-sig")
    (stage / "data").mkdir(exist_ok=True)
    (stage / "data" / ".gitkeep").write_text("", encoding="utf-8")

    zip_path = OUT_DIR / f"{folder_name}.zip"
    if zip_path.exists():
        zip_path.unlink()
    print("压缩中...", zip_path)
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for f in stage.rglob("*"):
            if f.is_file():
                zf.write(f, f.relative_to(stage.parent).as_posix())

    return zip_path


if __name__ == "__main__":
    path = build()
    print("DONE", path)
    print("size_mb", round(path.stat().st_size / 1024 / 1024, 2))
