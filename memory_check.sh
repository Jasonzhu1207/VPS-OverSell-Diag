#!/usr/bin/env bash

#
# VPS Oversell Possibility Check Script (v5 - Professional Edition)
#
# Description:
# A comprehensive script to detect VPS overselling by focusing on performance metrics
# and virtualization artifacts. Designed to be robust, adaptive, and user-guiding.
#
# Changelog (v5):
# 1. Removed: CPU Model check, to focus purely on performance and overselling techniques.
# 2. Enhanced I/O Tests: Memory test now falls back to /tmp if /dev/shm is unavailable.
#    Disk test has improved error handling.
# 3. New: Smart Dependency Check. The script now detects missing commands and provides
#    the exact installation command for the user's package manager (apt/yum/dnf).
#

# --- Helper function for colored output ---
print_color() {
    COLOR_CODE=$1
    shift
    echo -e "\033[${COLOR_CODE}m$@\033[0m"
}

# --- Script Header ---
print_color "33" "VPS 资源超售可能性检测脚本 (专业增强版 v5)"
print_color "0"  "================================================"

# --- 0. Smart Dependency Check & Fix Advisor ---
print_color "36" "[0/5] 依赖环境诊断与修复建议"
MISSING_CMDS=()
check_command() {
    if ! command -v "$1" &>/dev/null; then
        MISSING_CMDS+=("$1")
    fi
}

# List of essential commands
for cmd in dd vmstat awk lsmod grep sed cat; do
    check_command "$cmd"
done

if [ ${#MISSING_CMDS[@]} -gt 0 ]; then
    print_color "31" "检测到缺失的核心命令: ${MISSING_CMDS[*]}"
    PKG_MANAGER=""
    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt-get"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
    fi

    if [ -n "$PKG_MANAGER" ]; then
        print_color "33" "请尝试运行以下命令安装缺失的依赖包:"
        if [[ " ${MISSING_CMDS[*]} " =~ " vmstat " ]] || [[ " ${MISSING_CMDS[*]} " =~ " lsmod " ]]; then
             case "$PKG_MANAGER" in
                "apt-get") print_color "32" "sudo apt-get update && sudo apt-get install -y procps kmod";;
                "yum"|"dnf") print_color "32" "sudo $PKG_MANAGER install -y procps-ng kmod";;
             esac
        fi
        if [[ " ${MISSING_CMDS[*]} " =~ " dd " ]] || [[ " ${MISSING_CMDS[*]} " =~ " cat " ]]; then
             case "$PKG_MANAGER" in
                "apt-get") print_color "32" "sudo apt-get install -y coreutils";;
                "yum"|"dnf") print_color "32" "sudo $PKG_MANAGER install -y coreutils";;
             esac
        fi
    fi
    print_color "31" "部分检测可能无法进行，直到依赖被满足。"
else
    print_color "32" "核心依赖环境满足要求。"
fi
print_color "0" "------------------------------------------------"

# --- 1. Memory Performance Check ---
print_color "36" "[1/5] 内存性能检测 (判断母机Swap可能性)"
print_color "33" "说明: 内存写入速度过低(如<500MB/s)可能表示母机性能不佳或使用硬盘(Swap)超售。"
TEST_PATH=""
if [ -d /dev/shm ] && [ -w /dev/shm ]; then
    TEST_PATH="/dev/shm"
    print_color "32" "使用 /dev/shm 进行内存测试。"
else
    TEST_PATH="/tmp"
    print_color "33" "注意: /dev/shm 不可用, 回退到 /tmp 进行测试。结果可能受磁盘影响。"
fi

SPEED_INFO=$(LC_ALL=C dd if=/dev/zero of="${TEST_PATH}/test.tmp" bs=1M count=256 2>&1)
EXIT_CODE=$?
rm -f "${TEST_PATH}/test.tmp" &>/dev/null

if [ $EXIT_CODE -eq 0 ]; then
    SPEED_RAW=$(echo "$SPEED_INFO" | awk 'END{print $NF}')
    SPEED_VALUE=$(echo "$SPEED_RAW" | sed 's/[^0-9.]*//g')
    SPEED_UNIT=$(echo "$SPEED_RAW" | sed 's/[0-9.]*//g')
    SPEED_MB=0
    if [[ "$SPEED_UNIT" == "GB/s" ]]; then
        SPEED_MB=$(awk -v speed="$SPEED_VALUE" 'BEGIN{printf "%.0f", speed * 1024}')
    elif [[ "$SPEED_UNIT" == "kB/s" ]]; then
        SPEED_MB=$(awk -v speed="$SPEED_VALUE" 'BEGIN{printf "%.0f", speed / 1024}')
    elif [[ "$SPEED_UNIT" == "MB/s" ]]; then
        SPEED_MB=$(awk -v speed="$SPEED_VALUE" 'BEGIN{printf "%.0f", speed}')
    fi

    THRESHOLD=500
    print_color "34" "内存写入速度: ${SPEED_MB} MB/s"
    if [ "$SPEED_MB" -lt "$THRESHOLD" ] && [ "$TEST_PATH" == "/dev/shm" ]; then
        print_color "31" "警告: 内存写入速度较低 (低于 ${THRESHOLD}MB/s)，母机有使用Swap超售的嫌疑。"
    else
        print_color "32" "内存性能正常。"
    fi
else
    print_color "31" "内存性能测试失败 (dd命令执行错误)。"
fi
print_color "0" "------------------------------------------------"

# --- 2. Disk I/O Performance Check ---
print_color "36" "[2/5] 磁盘 I/O 性能检测"
print_color "33" "说明: 测试磁盘直接写入速度，判断IO是否被严重限制。"
IO_INFO=$(LC_ALL=C dd if=/dev/zero of=test_io.tmp bs=64k count=16k oflag=direct 2>&1)
IO_EXIT_CODE=$?
rm -f test_io.tmp &>/dev/null

if [ $IO_EXIT_CODE -eq 0 ]; then
    IO_SPEED_RAW=$(echo "$IO_INFO" | awk 'END{print $NF}')
    IO_SPEED_VALUE=$(echo "$IO_SPEED_RAW" | sed 's/[^0-9.]*//g')
    IO_SPEED_UNIT=$(echo "$IO_SPEED_RAW" | sed 's/[0-9.]*//g')
    IO_SPEED_MB=0
    if [[ "$IO_SPEED_UNIT" == "GB/s" ]]; then
        IO_SPEED_MB=$(awk -v speed="$IO_SPEED_VALUE" 'BEGIN{printf "%.0f", speed * 1024}')
    elif [[ "$IO_SPEED_UNIT" == "MB/s" ]]; then
        IO_SPEED_MB=$(awk -v speed="$IO_SPEED_VALUE" 'BEGIN{printf "%.0f", speed}')
    fi

    IO_THRESHOLD=100
    print_color "34" "磁盘直接写入速度: ${IO_SPEED_MB} MB/s"
    if [ "$IO_SPEED_MB" -lt "$IO_THRESHOLD" ]; then
        print_color "31" "警告: 磁盘I/O速度较低 (低于 ${IO_THRESHOLD}MB/s)，硬盘性能差或I/O被严重限制。"
    else
        print_color "32" "磁盘I/O性能正常。"
    fi
else
    print_color "31" "磁盘I/O测试失败 (可能是权限不足或不支持 oflag=direct)。"
fi
print_color "0" "------------------------------------------------"

# --- 3. Balloon Driver Check ---
print_color "36" "[3/5] 气球驱动 (virtio_balloon) 检测"
if lsmod | grep -q virtio_balloon; then
    print_color "31" "检测到 virtio_balloon 驱动已加载。"
    print_color "33" "说明: 这表明母机具备动态回收您VPS内存的能力，是内存超售的技术标志。"
    if [ -f /sys/class/balloon/balloon0/current_memory ]; then
        current_mb=$(( $(cat /sys/class/balloon/balloon0/current_memory) / 1024 ))
        target_mb=$(( $(cat /sys/class/balloon/balloon0/target_memory) / 1024 ))
        print_color "34" "气球当前内存: ${current_mb} MB | 目标内存: ${target_mb} MB"
        if [ "$current_mb" -ne "$target_mb" ]; then
            print_color "31" "警告: 当前内存与目标不一致，内存正在或曾经被动态调整！"
        else
            print_color "32" "内存暂未被回收。注意：驱动存在即代表有超售能力。"
        fi
    else
        print_color "33" "注意: 无法读取具体气球内存用量(内核可能被定制)，但驱动存在是明确风险信号。"
    fi
else
    print_color "32" "未发现 virtio_balloon 驱动。"
fi
print_color "0" "------------------------------------------------"

# --- 4. KSM (Kernel Samepage Merging) Check ---
print_color "36" "[4/5] KSM (内存合并) 检测"
if [ -f /sys/kernel/mm/ksm/run ] && [ "$(cat /sys/kernel/mm/ksm/run)" -eq 1 ]; then
    print_color "31" "检测到 KSM 已启用。"
    print_color "33" "说明: KSM是典型的内存超售技术。"
    pages_sharing=$(cat /sys/kernel/mm/ksm/pages_sharing)
    saved_mem=$((pages_sharing * 4 / 1024))
    print_color "34" "当前共享页面数: ${pages_sharing} (约节省 ${saved_mem} MB 内存)"
else
    print_color "32" "KSM 未启用。"
fi
print_color "0" "------------------------------------------------"

# --- 5. CPU Steal Time Check ---
print_color "36" "[5/5] CPU Steal Time (窃取时间) 检测"
print_color "33" "说明: CPU资源被母机上其他VPS“偷走”的百分比，持续高于5%是CPU超售的强力信号。"
STEAL_TIME=$(vmstat 1 2 | tail -1 | awk '{print $16}')
print_color "34" "当前 CPU Steal Time: ${STEAL_TIME}%"

if command -v bc &> /dev/null; then
    if (( $(echo "$STEAL_TIME > 5.0" | bc -l) )); then
        print_color "31" "警告: CPU Steal Time 偏高！强烈表明CPU资源被严重超售。"
    else
        print_color "32" "CPU Steal Time 处于正常范围。"
    fi
else
    STEAL_TIME_INT=${STEAL_TIME%.*}
    if [ "$STEAL_TIME_INT" -gt 5 ]; then
        print_color "31" "警告: CPU Steal Time 偏高！强烈表明CPU资源被严重超售。"
    else
        print_color "32" "CPU Steal Time 处于正常范围。"
    fi
    print_color "33" "(提示: 未安装 'bc'，已执行整数比较)"
fi
print_color "0" "------------------------------------------------"

# --- End of Script ---
print_color "33" "检测结束。"
print_color "35" "总结: 请综合内存/磁盘性能、以及虚拟化技术指标(Balloon, KSM, Steal Time)进行判断。"
