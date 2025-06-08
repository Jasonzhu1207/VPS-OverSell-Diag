#!/usr/bin/env bash

#
# VPS Oversell Possibility Check Script (v4 - Professional Edition)
#
# Description:
# This script provides a comprehensive check for common VPS overselling techniques.
# It's designed to be robust, adaptable, and provide deep insights.
#
# Changelog (v4):
# 1. New: Added CPU Model and Core count display to identify host hardware quality.
# 2. New: Added Disk I/O performance benchmark to detect storage overselling.
# 3. Enhanced: CPU Steal Time check is now adaptive. It uses 'bc' for precision
#    if available, otherwise gracefully falls back to integer comparison.
# 4. Refined: Re-ordered checks for a more logical diagnostic flow.
#

# --- Helper function for colored output ---
print_color() {
    COLOR_CODE=$1
    shift
    echo -e "\033[${COLOR_CODE}m$@\033[0m"
}

# --- Script Header ---
print_color "33" "VPS 资源超售可能性检测脚本 (专业增强版 v4)"
print_color "0"  "=============================================="

# --- 0. Dependency Check ---
print_color "36" "[0/6] 依赖环境检查"
COMMANDS_OK=true
for cmd in dd vmstat awk lscpu; do
    if ! command -v $cmd &> /dev/null; then
        print_color "31" "警告: 命令 '$cmd' 未找到。部分检测功能可能受限。"
        # Do not exit, just warn, to allow other checks to run
    fi
done
print_color "32" "依赖检查完成。"
print_color "0" "----------------------------------------------"


# --- 1. CPU Information ---
print_color "36" "[1/6] CPU 信息检测"
print_color "33" "说明: 可判断服务商是否使用老旧或低性能CPU。"
if command -v lscpu &> /dev/null; then
    CPU_MODEL=$(lscpu | grep "Model name:" | sed 's/Model name:[ \t]*//g')
    CPU_CORES=$(lscpu | grep "^CPU(s):" | awk '{print $2}')
    print_color "34" "CPU 型号: ${CPU_MODEL:-未知}"
    print_color "34" "核心数量: ${CPU_CORES:-未知} Cores"
else
    print_color "31" "未找到 'lscpu' 命令，跳过此项检测。"
fi
print_color "0" "----------------------------------------------"


# --- 2. Memory Performance Check ---
print_color "36" "[2/6] 内存性能检测 (判断母机Swap可能性)"
print_color "33" "说明: 内存写入速度过低(如<500MB/s)可能表示母机性能不佳或使用硬盘(Swap)超售。"
SPEED_INFO=$(LC_ALL=C dd if=/dev/zero of=/dev/shm/test.tmp bs=1M count=256 2>&1)
rm -f /dev/shm/test.tmp &>/dev/null
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

if [ "$SPEED_MB" -gt 0 ]; then
    THRESHOLD=500
    print_color "34" "内存写入速度: ${SPEED_MB} MB/s"
    if [ "$SPEED_MB" -lt "$THRESHOLD" ]; then
        print_color "31" "警告: 内存写入速度较低 (低于 ${THRESHOLD}MB/s)，母机有使用Swap超售的嫌疑。"
    else
        print_color "32" "内存性能正常。"
    fi
else
    print_color "31" "内存性能测试失败，可能是 /dev/shm 不可用。"
fi
print_color "0" "----------------------------------------------"


# --- 3. Disk I/O Performance Check ---
print_color "36" "[3/6] 磁盘 I/O 性能检测"
print_color "33" "说明: 测试磁盘直接写入速度，判断IO是否被严重限制。"
IO_INFO=$(LC_ALL=C dd if=/dev/zero of=test_io.tmp bs=64k count=16k oflag=direct 2>&1)
rm -f test_io.tmp
IO_SPEED_RAW=$(echo "$IO_INFO" | awk 'END{print $NF}')
IO_SPEED_VALUE=$(echo "$IO_SPEED_RAW" | sed 's/[^0-9.]*//g')
IO_SPEED_UNIT=$(echo "$IO_SPEED_RAW" | sed 's/[0-9.]*//g')
IO_SPEED_MB=0
if [[ "$IO_SPEED_UNIT" == "GB/s" ]]; then
    IO_SPEED_MB=$(awk -v speed="$IO_SPEED_VALUE" 'BEGIN{printf "%.0f", speed * 1024}')
elif [[ "$IO_SPEED_UNIT" == "MB/s" ]]; then
    IO_SPEED_MB=$(awk -v speed="$IO_SPEED_VALUE" 'BEGIN{printf "%.0f", speed}')
fi

if [ "$IO_SPEED_MB" -gt 0 ]; then
    IO_THRESHOLD=100
    print_color "34" "磁盘直接写入速度: ${IO_SPEED_MB} MB/s"
    if [ "$IO_SPEED_MB" -lt "$IO_THRESHOLD" ]; then
        print_color "31" "警告: 磁盘I/O速度较低 (低于 ${IO_THRESHOLD}MB/s)，硬盘性能差或I/O被严重限制。"
    else
        print_color "32" "磁盘I/O性能正常。"
    fi
else
    print_color "31" "磁盘I/O测试失败。"
fi
print_color "0" "----------------------------------------------"


# --- 4. Balloon Driver Check ---
print_color "36" "[4/6] 气球驱动 (virtio_balloon) 检测"
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
print_color "0" "----------------------------------------------"


# --- 5. KSM (Kernel Samepage Merging) Check ---
print_color "36" "[5/6] KSM (内存合并) 检测"
if [ -f /sys/kernel/mm/ksm/run ] && [ "$(cat /sys/kernel/mm/ksm/run)" -eq 1 ]; then
    print_color "31" "检测到 KSM 已启用。"
    print_color "33" "说明: KSM是典型的内存超售技术。"
    pages_sharing=$(cat /sys/kernel/mm/ksm/pages_sharing)
    saved_mem=$((pages_sharing * 4 / 1024))
    print_color "34" "当前共享页面数: ${pages_sharing} (约节省 ${saved_mem} MB 内存)"
else
    print_color "32" "KSM 未启用。"
fi
print_color "0" "----------------------------------------------"


# --- 6. CPU Steal Time Check ---
print_color "36" "[6/6] CPU Steal Time (窃取时间) 检测"
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
print_color "0" "----------------------------------------------"

# --- End of Script ---
print_color "33" "检测结束。"
print_color "35" "总结: 请综合CPU型号、内存/磁盘性能、以及虚拟化技术指标(Balloon, KSM, Steal Time)进行判断。"

