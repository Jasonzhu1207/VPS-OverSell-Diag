#!/usr/bin/env bash

#
# VPS Diagnostics Toolkit (v12)
#
# Description:
# An advanced, self-provisioning diagnostic script to evaluate VPS performance. It features
# an optional full-test mode for in-depth analysis using professional tools.
#
# Changelog (v12):
# 1. Critical Fix (Scope): Moved the 'RESULTS' associative array declaration to the
#    global scope. This fixes a critical bug where results from check functions were
#    not saved, leading to empty JSON output and incorrect reports.
#

# --- Safe Execution & Cleanup ---
set -euo pipefail
trap 'rm -f test_io.tmp fio_test_file*.tmp' EXIT

# --- Global Variables & Default Settings ---
VERSION="12.0"
DISK_WARN_MBPS=0 # Will be set dynamically
MEM_WARN_MBPS=500
STEAL_WARN_PERCENT=5
JSON_OUTPUT=false
SKIP_IO=false
FULL_TEST=false
VIRT_TYPE="unknown"
declare -A RESULTS

# --- Helper function for colored output ---
print_color() {
    # $1: color code, $2: text
    if [[ "${JSON_OUTPUT}" == false ]]; then
        echo -e "\033[${1}m${2}\033[0m"
    fi
}

# --- Command-Line Argument Parsing ---
parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --disk-warn-mbps) DISK_WARN_MBPS="$2"; shift ;;
            --mem-warn-mbps) MEM_WARN_MBPS="$2"; shift ;;
            --steal-warn-percent) STEAL_WARN_PERCENT="$2"; shift ;;
            --full-test) FULL_TEST=true ;;
            --json) JSON_OUTPUT=true ;;
            --skip-io) SKIP_IO=true ;;
            -h|--help) show_help; exit 0 ;;
            *) echo "Unknown parameter passed: $1"; exit 1 ;;
        esac
        shift
    done
}

show_help() {
    echo "VPS 诊断工具 (v${VERSION})"
    echo "用法: $0 [选项]"
    echo
    echo "选项:"
    echo "  --disk-warn-mbps <值>   设置磁盘I/O警告阈值 (MB/s) (默认: 动态检测)."
    echo "  --mem-warn-mbps <值>    设置内存速度警告阈值 (MB/s) (默认: ${MEM_WARN_MBPS})."
    echo "  --steal-warn-percent <值> 设置CPU窃取时间警告阈值 (%) (默认: ${STEAL_WARN_PERCENT})."
    echo "  --full-test              执行更全面的(但更耗时)内存和磁盘性能测试."
    echo "  --skip-io                跳过磁盘和内存I/O性能测试."
    echo "  --json                   以JSON格式输出结果."
    echo "  -h, --help               显示此帮助信息."
}

# --- Core Check Functions ---

install_dependencies() {
    print_color "36" "[0/5] 依赖自动安装程序"
    local pkgs_to_install=()
    local tools_to_check=("fio" "mpstat" "bc" "sysbench")
    
    if ! command -v virt-what &>/dev/null && ! command -v systemd-detect-virt &>/dev/null; then
        tools_to_check+=("virt-what")
    fi

    for tool in "${tools_to_check[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            case "$tool" in
                fio) pkgs_to_install+=("fio") ;;
                mpstat) pkgs_to_install+=("sysstat") ;;
                bc) pkgs_to_install+=("bc") ;;
                sysbench) pkgs_to_install+=("sysbench") ;;
                "virt-what") pkgs_to_install+=("virt-what") ;;
            esac
        fi
    done
    
    pkgs_to_install=($(echo "${pkgs_to_install[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

    if [ ${#pkgs_to_install[@]} -eq 0 ]; then
        print_color "32" "所有推荐的诊断工具均已安装."
        RESULTS[dependencies_status]="OK"
        return
    fi

    print_color "33" "正在尝试自动安装缺失的工具包: ${pkgs_to_install[*]}"
    local pm=""
    if command -v apt-get &>/dev/null; then pm="apt"; fi
    if command -v yum &>/dev/null; then pm="yum"; fi
    if command -v dnf &>/dev/null; then pm="dnf"; fi

    if [ -z "$pm" ]; then
        print_color "31" "错误: 无法检测到包管理器 (apt/yum/dnf)。请手动安装依赖项。"
        exit 1
    fi
    
    local install_cmd=""
    if [ "$(id -u)" -eq 0 ]; then
        install_cmd=""
    elif command -v sudo &>/dev/null; then
        install_cmd="sudo"
    else
        print_color "31" "错误: 此脚本需要 root 权限或 'sudo' 来安装依赖项。正在中止。"
        exit 1
    fi

    case "$pm" in
        "apt")
            $install_cmd apt-get update -y
            $install_cmd apt-get install -y "${pkgs_to_install[@]}"
            ;;
        "yum"|"dnf")
            $install_cmd "$pm" install -y "${pkgs_to_install[@]}"
            ;;
    esac
    
    print_color "32" "依赖安装过程完成。"
    RESULTS[dependencies_status]="installed_attempted"
}

check_virt_type() {
    print_color "36" "[1/5] 虚拟化技术检测"
    if command -v systemd-detect-virt &>/dev/null; then
        VIRT_TYPE=$(systemd-detect-virt)
    elif command -v virt-what &>/dev/null; then
        VIRT_TYPE=$(virt-what)
    fi
    print_color "34" "检测到的虚拟化技术: ${VIRT_TYPE}"
    RESULTS[virt_type]=$VIRT_TYPE
}

run_memory_test() {
    if [[ "$SKIP_IO" == true ]]; then print_color "33" "[2/5] 内存性能测试 (已跳过)"; return; fi
    print_color "36" "[2/5] 内存性能测试"
    
    if [[ "$FULL_TEST" == true ]] && command -v sysbench &>/dev/null; then
        print_color "32" "方法: 'sysbench' 深度内存带宽测试."
        local mem_output
        mem_output=$(sysbench memory --memory-block-size=1M --memory-total-size=10G run)
        local speed_mb
        speed_mb=$(echo "$mem_output" | grep "MiB/sec" | awk -F'(' '{print $2}' | awk '{printf "%.0f", $1}')
        RESULTS[memory_mbps]=$speed_mb
        print_color "34" "结果: ${speed_mb} MB/s"
        if [ "$speed_mb" -lt "$MEM_WARN_MBPS" ]; then
            print_color "31" "警告: 内存速度低于阈值 (${MEM_WARN_MBPS} MB/s)."
        fi
    else
        print_color "32" "方法: 'dd' 基础页缓存吞吐量测试."
        local test_path=""
        if [ -d /dev/shm ] && [ -w /dev/shm ]; then
            test_path="/dev/shm"
        else
            test_path="/tmp"
            print_color "33" "注意: /dev/shm 不可用, 回退到 /tmp 进行测试。"
        fi

        local speed_info
        if ! speed_info=$(LC_ALL=C dd if=/dev/zero of="${test_path}/test.tmp" bs=1M count=256 2>&1); then
            print_color "31" "测试失败: 'dd' 命令执行错误。"
            RESULTS[memory_mbps]=-1
            return
        fi
        
        local speed_line speed_raw speed_value speed_unit speed_mb=0
        speed_line=$(echo "$speed_info" | tail -n 1)
        speed_raw=$(echo "$speed_line" | awk -F, '{print $NF}' | sed 's/^[ \t]*//')
        speed_value=$(echo "$speed_raw" | sed 's/[^0-9.]*//g')
        speed_unit=$(echo "$speed_raw" | sed 's/[0-9.]*//g' | sed 's/ //g')

        if [[ "$speed_unit" == "GB/s" ]]; then
            speed_mb=$(awk -v speed="$speed_value" 'BEGIN{printf "%.0f", speed * 1024}')
        elif [[ "$speed_unit" == "MB/s" ]]; then
            speed_mb=$(awk -v speed="$speed_value" 'BEGIN{printf "%.0f", speed}')
        fi

        RESULTS[memory_mbps]=$speed_mb
        print_color "34" "结果: ${speed_mb} MB/s"
    fi
}

run_disk_test() {
    if [[ "$SKIP_IO" == true ]]; then print_color "33" "[3/5] 磁盘I/O性能测试 (已跳过)"; return; fi
    print_color "36" "[3/5] 磁盘I/O性能测试"
    
    if ! command -v fio &>/dev/null; then
        print_color "31" "测试失败: 'fio' 是必需的但未安装。自动安装可能已失败。"
        RESULTS[disk_mbps]=-1
        return
    fi
    
    if [ "$DISK_WARN_MBPS" -eq 0 ]; then
        local rota=1
        if command -v lsblk &>/dev/null; then
            local current_disk
            current_disk=$(df . | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
            rota=$(lsblk -d -n -o ROTA "$current_disk" 2>/dev/null || echo 1)
        fi
        if [ "$rota" -eq 0 ]; then
            DISK_WARN_MBPS=200
            print_color "32" "检测到非机械硬盘(SSD/NVMe), 使用 ${DISK_WARN_MBPS} MB/s 作为随机写警告阈值。"
        else
            DISK_WARN_MBPS=80
            print_color "32" "检测到机械硬盘(HDD), 使用 ${DISK_WARN_MBPS} MB/s 作为随机写警告阈值。"
        fi
    fi
    
    if [[ "$FULL_TEST" == true ]]; then
        print_color "32" "方法: 'fio' 深度基准测试 (多种场景)."
        local tests=("randread" "randwrite" "read" "write")
        local block_sizes=("4k" "4k" "1M" "1M")
        local labels=("4k 随机读" "4k 随机写" "1M 顺序读" "1M 顺序写")
        
        for i in "${!tests[@]}"; do
            local test_type="${tests[$i]}"
            local bs="${block_sizes[$i]}"
            local label="${labels[$i]}"
            
            print_color "34" "  -> 正在运行: ${label}"
            local fio_output
            fio_output=$(fio --name="${test_type}" --ioengine=libaio --iodepth=64 --rw="${test_type}" --bs="${bs}" --direct=1 --size=256M --numjobs=1 --runtime=10 --filename="fio_test_file_${test_type}.tmp" --group_reporting 2>/dev/null || echo "error")
            
            if [[ "$fio_output" == "error" ]]; then
                print_color "31" "     测试失败: 'fio' 命令执行错误。"
                RESULTS["disk_${test_type}_mbps"]=-1
            else
                local speed_mb
                speed_mb=$(echo "$fio_output" | grep -oP 'bw=\K[0-9.]+(?=MiB/s)' | awk '{printf "%.0f", $1}')
                RESULTS["disk_${test_type}_mbps"]=$speed_mb
                print_color "34" "     结果: ${speed_mb} MB/s"
            fi
        done
    else
        print_color "32" "方法: 'fio' 基础基准测试 (4k 随机写入)."
        local fio_output speed_mb
        if ! fio_output=$(fio --name=test --ioengine=libaio --iodepth=64 --rw=randwrite --bs=4k --direct=1 --size=256M --numjobs=1 --runtime=10 --filename=fio_test_file.tmp --group_reporting 2>&1); then
             print_color "31" "测试失败: 'fio' 命令执行错误。"
             RESULTS[disk_randwrite_mbps]=-1
             return
        fi
        speed_mb=$(echo "$fio_output" | grep -oP 'bw=\K[0-9.]+(?=MiB/s)' | awk '{printf "%.0f", $1}')
        RESULTS[disk_randwrite_mbps]=$speed_mb
        RESULTS[disk_warn_threshold]=$DISK_WARN_MBPS
        print_color "34" "结果: ${speed_mb} MB/s"
        if [ "$speed_mb" -lt "$DISK_WARN_MBPS" ]; then
            print_color "31" "警告: 磁盘随机写速度低于阈值 (${DISK_WARN_MBPS} MB/s)."
        fi
    fi
}

check_kvm_features() {
    print_color "36" "[4/5] KVM 特定功能检查"
    if [[ "$VIRT_TYPE" != "kvm" && "$VIRT_TYPE" != "qemu" ]]; then
      print_color "33" "状态: 已跳过 (非KVM/QEMU环境)"
      RESULTS[balloon_driver]="not_applicable"
      RESULTS[ksm_enabled]="not_applicable"
      return
    fi
    
    if lsmod | grep -q virtio_balloon; then
        print_color "33" "指标 (virtio_balloon): 驱动已加载。这使得主机能够动态回收内存，是超售的一种能力。"
        RESULTS[balloon_driver]="loaded"
    else
        print_color "32" "指标 (virtio_balloon): 驱动未加载。"
        RESULTS[balloon_driver]="not_loaded"
    fi

    if [ -f /sys/kernel/mm/ksm/run ] && [ "$(cat /sys/kernel/mm/ksm/run)" -eq 1 ]; then
        print_color "33" "指标 (KSM): 已启用。此内存节省功能常用于高密度虚拟化环境。"
        RESULTS[ksm_enabled]=true
    else
        print_color "32" "指标 (KSM): 未启用。"
        RESULTS[ksm_enabled]=false
    fi
}

run_cpu_steal_test() {
    print_color "36" "[5/5] CPU 窃取时间分析"
    
    if ! command -v mpstat &>/dev/null; then
        print_color "31" "测试失败: 'mpstat' 是必需的但未安装。自动安装可能已失败。"
        RESULTS[cpu_steal_percent]=-1
        return
    fi

    print_color "32" "方法: 'mpstat' 分析 (10秒平均值)。"
    local steal_avg
    steal_avg=$(LANG=C mpstat -P ALL 1 10 | grep "^Average:" | tail -n 1 | awk '{print $(NF-3)}')
    
    RESULTS[cpu_steal_percent]=$steal_avg
    print_color "34" "结果: ${steal_avg}% 平均窃取时间。"
    
    if command -v bc &>/dev/null; then
        if (( $(echo "$steal_avg > $STEAL_WARN_PERCENT" | bc -l) )); then
            print_color "31" "警告: CPU 窃取时间高于阈值 (${STEAL_WARN_PERCENT}%)。"
        fi
    else
        local steal_avg_int=${steal_avg%.*}
        if [ "$steal_avg_int" -ge "$STEAL_WARN_PERCENT" ]; then
            print_color "31" "警告: CPU 窃取时间高于阈值 (${STEAL_WARN_PERCENT}%)。"
        fi
    fi
}

# --- Main Execution Logic ---
main() {
    parse_args "$@"
    
    if [[ "$JSON_OUTPUT" == false ]]; then
        print_color "33" "VPS 诊断工具 (v${VERSION})"
        print_color "0"  "================================================"
    fi

    install_dependencies
    print_color "0" "------------------------------------------------"
    check_virt_type
    print_color "0" "------------------------------------------------"
    run_memory_test
    print_color "0" "------------------------------------------------"
    run_disk_test
    print_color "0" "------------------------------------------------"
    check_kvm_features
    print_color "0" "------------------------------------------------"
    run_cpu_steal_test

    if [[ "$JSON_OUTPUT" == true ]]; then
        printf "{\n"
        for key in "${!RESULTS[@]}"; do
            val="${RESULTS[$key]}"
            val_escaped=$(echo "$val" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
            if [[ "$val" =~ ^[0-9.-]+$ ]] || [[ "$val" == "true" ]] || [[ "$val" == "false" ]]; then
                 printf '  "%s": %s,\n' "$key" "$val_escaped"
            else
                 printf '  "%s": "%s",\n' "$key" "$val_escaped"
            fi
        done | sed '$ s/,$//'
        printf "}\n"
    else
        print_color "0"  "------------------------------------------------"
        print_color "33" "诊断完成。"
        print_color "35" "免责声明: 此结果为诊断指标, 并非超售的最终定论。"
        print_color "35" "请结合您的应用实际性能进行综合判断。"
    fi
}

main "$@"
