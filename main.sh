#!/usr/bin/env bash

#
# VPS Diagnostics Toolkit - Runner Script (v3)
#
# Description:
# This script securely downloads the latest version of the main diagnostic script.
# It now defaults to running the comprehensive '--full-test' if no arguments are given.
# Otherwise, it passes all provided arguments to the main script.
#

# --- Safe Execution & Cleanup ---
set -eo pipefail
trap 'rm -f "$temp_script"' EXIT

# --- Configuration ---
SCRIPT_URL="https://raw.githubusercontent.com/jasonzhu1207/memoryCheck/main/memory_check.sh"

# --- Helper function for colored output ---
print_color() {
    echo -e "\033[${1}m${2}\033[0m"
}


# --- Main Logic ---
print_color "33" "== VPS 诊断工具启动程序 =="

# 1. Create a secure temporary file
temp_script=$(mktemp)

# 2. Download the latest script
print_color "36" "-> 正在下载最新版本的诊断脚本..."
if command -v curl &>/dev/null; then
    if ! curl -fsSL "$SCRIPT_URL" -o "$temp_script"; then
        print_color "31" "错误: 使用 curl 下载脚本失败。请检查网络连接或URL。"
        exit 1
    fi
elif command -v wget &>/dev/null; then
    if ! wget -qO "$temp_script" "$SCRIPT_URL"; then
        print_color "31" "错误: 使用 wget 下载脚本失败。请检查网络连接或URL。"
        exit 1
    fi
else
    print_color "31" "错误: 系统中未找到 curl 或 wget。无法下载脚本。"
    exit 1
fi

# 3. Ensure the downloaded script is not empty
if ! [ -s "$temp_script" ]; then
    print_color "31" "错误: 下载的脚本文件为空，可能源文件有问题或下载被中断。"
    exit 1
fi

# 4. Make the script executable
chmod +x "$temp_script"

# 5. Execute the script, defaulting to --full-test if no arguments are given
print_color "36" "-> 准备执行诊断工具..."
print_color "0"  "================================================"

if [ $# -eq 0 ]; then
    print_color "33" "-> 未指定参数，默认执行 --full-test 深度测试..."
    bash "$temp_script" --full-test
else
    print_color "33" "-> 检测到自定义参数，将直接传递..."
    bash "$temp_script" "$@"
fi

# The 'trap' command will automatically clean up the temp_script on exit.
