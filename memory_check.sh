#!/usr/bin/env bash

#
# VPS Diagnostics Toolkit (v9)
#
# Description:
# A self-provisioning diagnostic script to evaluate VPS performance. It automatically
# attempts to install professional tools (fio, sysstat) to ensure accurate analysis,
# adapts to the virtualization technology, and offers robust, structured output.
#
# Changelog (v9):
# 1. Critical Fix (CPU Steal): Corrected the parsing logic for 'mpstat' to accurately
#    extract the '%steal' value, fixing the syntax error on some systems.
# 2. Robustness (CPU Compare): Re-implemented the CPU steal comparison to correctly
#    handle systems with and without the 'bc' utility.
# 3. Aesthetics: Re-introduced separators between sections for improved readability.
#    Renumbered check steps for clarity.
#

# --- Safe Execution & Cleanup ---
set -eo pipefail
trap 'rm -f test_io.tmp fio_test_file.tmp' EXIT

# --- Global Variables & Default Settings ---
VERSION="9.0"
DISK_WARN_MBPS=100
MEM_WARN_MBPS=500
STEAL_WARN_PERCENT=5
JSON_OUTPUT=false
SKIP_IO=false
VIRT_TYPE="unknown"

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
    echo "  --disk-warn-mbps <值>   设置磁盘I/O警告阈值 (MB/s) (默认: ${DISK_WARN_MBPS})."
    echo "  --mem-warn-mbps <值>    设置内存速度警告阈值 (MB/s) (默认: ${MEM_WARN_MBPS})."
    echo "  --steal-warn-percent <值> 设置CPU窃取时间警告阈值 (%) (默认: ${STEAL_WARN_PERCENT})."
    echo "  --skip-io                跳过磁盘和内存I/O性能测试."
    echo "  --json                   以JSON格式输出结果."
    echo "  -h, --help               显示此帮助信息."
}

# --- Core Check Functions ---

install_dependencies() {
    print_color "36" "[0/5] 依赖自动安装程序"
    local pkgs_to_install=()
    local pkg_map_fio="fio"
    local pkg_map_sysstat="sysstat"
    local pkg_map_virtwhat="virt-what"

    if ! command -v fio &>/dev/null; then pkgs_to_install+=($pkg_map_fio); fi
    if ! command -v mpstat &>/dev/null; then pkgs_to_install+=($pkg_map_sysstat); fi
    if ! command -v virt-what &>/dev/null && ! command -v systemd-detect-virt &>/dev/null; then
        pkgs_to_install+=($pkg_map_virtwhat)
    fi

    if [ ${#pkgs_to_install[@]} -eq 0 ]; then
        print_color "32" "所有推荐的诊断工具均已安装."
        RESULTS[dependencies]="OK"
        return
    fi

    print_color "33" "正在尝试自动安装缺失的工具: ${pkgs_to_install[*]}"
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
            $install_cmd apt-get update
            $install_cmd apt-get install -y "${pkgs_to_install[@]}"
            ;;
        "yum"|"dnf")
            $install_cmd "$pm" install -y "${pkgs_to_install[@]}"
            ;;
    esac
    
    print_color "32" "依赖安装过程完成。"
    RESULTS[dependencies]="installed_attempted"
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
    
    local test_path=""
    if [ -d /dev/shm ] && [ -w /dev/shm ]; then
        test_path="/dev/shm"
        print_color "32" "方法: 使用 'dd' 测试 /dev/shm (内存文件系统)."
    else
        test_path="/tmp"
        print_color "33" "注意: /dev/shm 不可用, 回退到 /tmp 进行测试。结果可能受磁盘影响。"
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
    if [ "$speed_mb" -lt "$MEM_WARN_MBPS" ] && [ "$test_path" == "/dev/shm" ]; then
        print_color "31" "警告: 内存速度低于阈值 (${MEM_WARN_MBPS} MB/s)."
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
    
    print_color "32" "方法: 'fio' 基准测试 (4k 随机写入, 直接 I/O)."
    local fio_output speed_mb
    if ! fio_output=$(fio --name=test --ioengine=libaio --iodepth=64 --rw=randwrite --bs=4k --direct=1 --size=256M --numjobs=1 --runtime=10 --filename=fio_test_file.tmp --group_reporting 2>&1); then
         print_color "31" "测试失败: 'fio' 命令执行错误。"
         RESULTS[disk_mbps]=-1
         return
    fi
    speed_mb=$(echo "$fio_output" | grep -oP 'bw=\K[0-9.]+(?=MiB/s)' | awk '{printf "%.0f", $1}')

    RESULTS[disk_mbps]=$speed_mb
    print_color "34" "结果: ${speed_mb} MB/s"
    if [ "$speed_mb" -lt "$DISK_WARN_MBPS" ]; then
        print_color "31" "警告: 磁盘I/O速度低于阈值 (${DISK_WARN_MBPS} MB/s)."
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
    
    # KVM Balloon Driver Check
    if lsmod | grep -q virtio_balloon; then
        print_color "33" "指标 (virtio_balloon): 驱动已加载。这使得主机能够动态回收内存，是超售的一种能力。"
        RESULTS[balloon_driver]="loaded"
    else
        print_color "32" "指标 (virtio_balloon): 驱动未加载。"
        RESULTS[balloon_driver]="not_loaded"
    fi

    # KSM Check
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

    print_color "32" "方法: 'mpstat' 分析 (5秒平均值)。"
    local steal_avg
    # Robustly parse the %steal column (4th from last) from the final average line
    steal_avg=$(mpstat -P ALL 1 5 | grep "^Average:" | tail -n 1 | awk '{print $(NF-3)}')
    
    RESULTS[cpu_steal_percent]=$steal_avg
    print_color "34" "结果: ${steal_avg}% 平均窃取时间。"
    
    # Robust comparison for float values, works with/without bc
    if command -v bc &>/dev/null; then
        if (( $(echo "$steal_avg > $STEAL_WARN_PERCENT" | bc -l) )); then
            print_color "31" "警告: CPU 窃取时间高于阈值 (${STEAL_WARN_PERCENT}%)。"
        fi
    else
        # Fallback to integer comparison if bc is not available
        local steal_avg_int=${steal_avg%.*}
        if [ "$steal_avg_int" -gt "$STEAL_WARN_PERCENT" ]; then
            print_color "31" "警告: CPU 窃取时间高于阈值 (${STEAL_WARN_PERCENT}%)。"
        fi
    fi
}

# --- Main Execution Logic ---
main() {
    declare -A RESULTS
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
        # Convert associative array to JSON
        json_str="{"
        for key in "${!RESULTS[@]}"; do
            val="${RESULTS[$key]}"
            # Check if value is numeric or boolean, otherwise quote it
            if [[ "$val" =~ ^[0-9.-]+$ ]] || [[ "$val" == "true" ]] || [[ "$val" == "false" ]]; then
                json_str+="\"${key}\":${val},"
            else
                json_str+="\"${key}\":\"${val}\","
            fi
        done
        echo "${json_str%,}}" # Remove trailing comma and close bracket
    else
        print_color "0"  "------------------------------------------------"
        print_color "33" "诊断完成。"
        print_color "35" "免责声明: 此结果为诊断指标, 并非超售的最终定论。"
        print_color "35" "请结合您的应用实际性能进行综合判断。"
    fi
}

main "$@"
