#!/usr/bin/env bash

#
# VPS Oversell Possibility Check Script (Optimized Version)
#
# Description:
# This script checks for common VPS overselling techniques by focusing on performance metrics
# and specific virtualization artifacts, rather than user-configurable settings.
#
# Changes based on feedback:
# 1. Memory Check: Replaced simple SWAP check with a memory I/O benchmark to detect
#    potential host-level swapping.
# 2. Balloon Driver: Made the check more robust to handle minimal systems where stats
#    files might be missing, focusing on the driver's presence as the primary indicator.
# 3. CPU Check: Replaced CPU usage with CPU Steal Time, a much more accurate metric for
#    CPU overselling.
#

# --- Helper function for colored output ---
print_color() {
    COLOR_CODE=$1
    shift
    echo -e "\033[${COLOR_CODE}m$@\033[0m"
}

# --- Script Header ---
print_color "33" "VPS 资源超售可能性检测脚本 (优化版)"
print_color "0"  "=============================================="

# --- 1. Memory Performance Check (Replaces SWAP check) ---
print_color "36" "[1/4] 内存性能检测 (判断母机Swap可能性)"
print_color "33" "说明: 测试内存写入速度。速度过低(如<500MB/s)可能表示母机使用硬盘(Swap)超售内存。"

# Perform a quick benchmark using dd on tmpfs (in-memory filesystem)
# The output of dd can vary, so we capture stderr to get the speed info
if ! SPEED_INFO=$(dd if=/dev/zero of=/dev/shm/test.tmp bs=1M count=256 2>&1); then
    # Some systems might not have /dev/shm, try /tmp if it's tmpfs
    if mount | grep -q 'on /tmp type tmpfs'; then
        SPEED_INFO=$(dd if=/dev/zero of=/tmp/test.tmp bs=1M count=256 2>&1)
        rm -f /tmp/test.tmp
    else
        print_color "31" "错误: 无法找到合适的内存文件系统 (如 /dev/shm) 进行测试。"
        SPEED_INFO=""
    fi
else
    rm -f /dev/shm/test.tmp # Clean up immediately
fi

if [ -n "$SPEED_INFO" ]; then
    # Extract the speed value and unit from the last field of dd's output
    SPEED_VALUE=$(echo "$SPEED_INFO" | awk -F, '{print $NF}' | sed 's/ //g' | sed 's/[a-zA-Z/]*//g')
    SPEED_UNIT=$(echo "$SPEED_INFO" | awk -F, '{print $NF}' | sed 's/ //g' | grep -o '[a-zA-Z/]*')

    # Normalize speed to MB/s for a consistent comparison
    SPEED_MB=0
    if [[ "$SPEED_UNIT" == "GB/s" ]]; then
        SPEED_MB=$(awk -v speed="$SPEED_VALUE" 'BEGIN{printf "%.0f", speed * 1024}')
    elif [[ "$SPEED_UNIT" == "kB/s" ]]; then
        SPEED_MB=$(awk -v speed="$SPEED_VALUE" 'BEGIN{printf "%.0f", speed / 1024}')
    elif [[ "$SPEED_UNIT" == "MB/s" ]]; then
        SPEED_MB=$(awk -v speed="$SPEED_VALUE" 'BEGIN{printf "%.0f", speed}')
    fi

    THRESHOLD=500 # 500 MB/s is a reasonable minimum for RAM.
    print_color "34" "检测到内存写入速度: ${SPEED_MB} MB/s"

    if (( SPEED_MB < THRESHOLD )); then
        print_color "31" "警告: 内存写入速度较低 (低于 ${THRESHOLD}MB/s)，母机有使用Swap超售的嫌疑。"
    else
        print_color "32" "内存性能正常，未见明显由母机Swap导致的性能问题。"
    fi
else
    print_color "33" "跳过内存性能检测。"
fi
print_color "0" "----------------------------------------------"


# --- 2. Balloon Driver Check (Optimized) ---
print_color "36" "[2/4] 气球驱动 (virtio_balloon) 超售检测"
if lsmod | grep -q virtio_balloon; then
    print_color "31" "检测到 virtio_balloon 驱动已加载。"
    print_color "33" "说明: 这表明母机具备动态回收您VPS内存的能力，是内存超售的技术标志。"
    
    # Check if specific stats files exist (can be missing on minimal systems)
    if [ -f /sys/class/balloon/balloon0/current_memory ] && [ -f /sys/class/balloon/balloon0/target_memory ]; then
        current_kb=$(cat /sys/class/balloon/balloon0/current_memory)
        target_kb=$(cat /sys/class/balloon/balloon0/target_memory)
        current_mb=$((current_kb / 1024))
        target_mb=$((target_kb / 1024))
        
        print_color "34" "气球当前内存: ${current_mb} MB"
        print_color "34" "气球目标内存: ${target_mb} MB"
        
        if [ "$current_kb" -ne "$target_kb" ]; then
            print_color "31" "警告: 当前内存与目标内存不一致，内存正在或曾经被动态调整！"
        else
            print_color "32" "当前内存与目标内存一致。注意：即使一致，驱动存在即代表有超售能力。"
        fi
    else
        print_color "33" "注意: 无法读取具体的气球内存使用情况 (可能是精简系统)。"
        print_color "33" "但驱动已加载是明确信号，表示服务商有能力随时回收您的内存。"
    fi
else
    print_color "32" "未发现 virtio_balloon 驱动，未使用此技术超售。"
fi
print_color "0" "----------------------------------------------"


# --- 3. KSM (Kernel Samepage Merging) Check ---
print_color "36" "[3/4] KSM (内存合并) 超售检测"
if [ -f /sys/kernel/mm/ksm/run ] && [ "$(cat /sys/kernel/mm/ksm/run)" -eq 1 ]; then
    print_color "31" "检测到 KSM (Kernel Samepage Merging) 已启用。"
    print_color "33" "说明: KSM会合并内存中相同的页面，以此在母机上节省内存，是内存超售的一种技术。"
    
    pages_sharing=$(cat /sys/kernel/mm/ksm/pages_sharing)
    saved_mem=$((pages_sharing * 4 / 1024)) # Assuming 4KB page size
    
    print_color "34" "当前共享页面数: ${pages_sharing} (约节省 ${saved_mem} MB 内存)"
else
    print_color "32" "KSM 未启用，未使用此技术超售。"
fi
print_color "0" "----------------------------------------------"


# --- 4. CPU Steal Time Check (Replaces CPU Usage) ---
print_color "36" "[4/4] CPU Steal Time (CPU窃取时间) 检测"
print_color "33" "说明: 该值表示CPU资源被母机上其他VPS“偷走”的百分比。持续高于5%是CPU超售的强力信号。"

# Using vmstat for more consistent output across systems than top
# The 'st' column is the 16th on most systems.
if ! command -v vmstat &> /dev/null; then
    print_color "31" "错误: 未找到 'vmstat' 命令，无法检测CPU Steal Time。"
else
    STEAL_TIME=$(vmstat 1 2 | tail -1 | awk '{print $16}')
    print_color "34" "当前 CPU Steal Time: ${STEAL_TIME}%"
    
    if (( $(echo "$STEAL_TIME > 5" | bc -l) )); then
        print_color "31" "警告: CPU Steal Time 偏高！这强烈表明CPU资源被严重超售。"
    else
        print_color "32" "CPU Steal Time 处于正常范围。"
    fi
fi
print_color "0" "----------------------------------------------"


# --- End of Script ---
print_color "33" "检测结束。"
print_color "35" "总结: 请综合以上四项指标进行判断。任何一项出现红色警告都值得警惕。"

