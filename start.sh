#!/bin/zsh
# 启动 WireGuard 控制台（前台运行，Ctrl+C 退出）
cd "$(dirname "$0")"
exec python3 server.py
