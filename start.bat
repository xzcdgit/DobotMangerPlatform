@echo off
chcp 65001 >nul
cd /d "%~dp0"
title 机器人可视化平台

where py >nul 2>nul
if %errorlevel%==0 (
  set "PY=py -3"
) else (
  where python >nul 2>nul
  if %errorlevel%==0 (
    set "PY=python"
  ) else (
    echo [错误] 未找到 Python。请先安装 Python 3.9+，并勾选 Add to PATH。
    echo 下载: https://www.python.org/downloads/
    pause
    exit /b 1
  )
)

if not exist "data" mkdir data
echo.
echo  机器人可视化平台
echo  端口见 config.json 的 port；启动后会自动打开浏览器
echo  关闭本窗口即停止服务
echo.
%PY% server.py
echo.
echo 服务已退出。
pause
