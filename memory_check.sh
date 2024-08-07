#!/usr/bin/env bash

echo -e "\033[33m内存超售检测开始\033[0m"
echo -e "\033[0m====================\033[0m"

# 检查是否使用了 SWAP 超售内存
echo -e "\033[36m检查是否使用了 SWAP 超售内存\033[0m"
swap_used=$(free -m | awk '/Swap/ {print $3}')
if [ $swap_used -gt 0 ]; then
    echo -e "\033[31m存在 SWAP 使用: ${swap_used}MB\033[0m"
    echo -e "\033[31m可能存在 SWAP 超售内存\033[0m"
else
    echo -e "\033[32m没有使用 SWAP\033[0m"
    echo -e "\033[32m未使用 SWAP 超售内存\033[0m"
fi
echo -e "\033[0m====================\033[0m"

# 检查是否使用了气球驱动 Balloon 超售内存
echo -e "\033[36m检查是否使用了 气球驱动 Balloon 超售内存\033[0m"
if lsmod | grep virtio_balloon > /dev/null; then
    echo -e "\033[31m存在 virtio_balloon 模块\033[0m"
    echo -e "\033[31m可能使用了 气球驱动 Balloon 超售内存\033[0m"
    if [ -f /sys/class/balloon/balloon0/current_memory ] && [ -f /sys/class/balloon/balloon0/target_memory ]; then
        balloon_current_mem=$(cat /sys/class/balloon/balloon0/current_memory)
        balloon_target_mem=$(cat /sys/class/balloon/balloon0/target_memory)
        echo -e "\033[34m气球当前内存分配: $balloon_current_mem\033[0m"
        echo -e "\033[34m气球目标内存分配: $balloon_target_mem\033[0m"
    else
        echo -e "\033[31m无法检测出气球当前内存分配和气球目标内存分配，请尝试更换Ubuntu系统并且不要使用精简版\033[0m"
    fi
else
    echo -e "\033[32m不存在 virtio_balloon 模块\033[0m"
    echo -e "\033[32m未使用 气球驱动 Balloon 超售内存\033[0m"
fi
echo -e "\033[0m====================\033[0m"

# 检查是否使用了 Kernel Samepage Merging (KSM) 超售内存
echo -e "\033[36m检查是否使用了 Kernel Samepage Merging (KSM) 超售内存\033[0m"
if [ -f /sys/kernel/mm/ksm/run ] && [ $(cat /sys/kernel/mm/ksm/run) -eq 1 ]; then
    echo -e "\033[31mKernel Samepage Merging 已启用\033{0m"
    echo -e "\033[31m可能使用了 Kernel Samepage Merging (KSM) 超售内存\033[0m"
    merged_pages=$(cat /sys/kernel/mm/ksm/pages_sharing)
    echo -e "\033[34m已合并页面数: $merged_pages\033[0m"
else
    echo -e "\033[32mKernel Samepage Merging 未启用\033[0m"
    echo -e "\033[32m未使用 Kernel Samepage Merging (KSM) 超售内存\033[0m"
fi
echo -e "\033[0m====================\033[0m"

# 添加更多的系统资源检查，例如 CPU 使用率
echo -e "\033[36m检查 CPU 使用率\033[0m"
cpu_usage=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
echo -e "\033[34m当前 CPU 使用率: ${cpu_usage}%\033[0m"
echo -e "\033[0m====================\033[0m"

echo -e "\033[33m内存超售检测结束\033[0m"
