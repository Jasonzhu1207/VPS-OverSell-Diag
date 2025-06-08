#!/usr/bin/env bash

#
# VPS Diagnostics Toolkit - Runner Script (v2)
#
# Description:
# This script securely downloads the latest version of the main diagnostic script,
# makes it executable, and runs it, passing along all command-line arguments.
# It ensures stability with error checking and robust cleanup.
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

# 5. Execute the script, passing all arguments transparently
print_color "36" "-> 准备执行诊断工具"
print_color "0"  "================================================"

bash "$temp_script" "$@"

# The 'trap' command will automatically clean up the temp_script on exit.
# The explicit rm call is therefore not needed but left here for clarity in older scripts.
# rm "$temp_script"
