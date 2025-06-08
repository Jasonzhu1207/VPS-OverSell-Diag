#!/usr/bin/env bash

#
# VPS Diagnostics Toolkit (v8)
#
# Description:
# A self-provisioning diagnostic script to evaluate VPS performance. It automatically
# attempts to install professional tools (fio, sysstat) to ensure accurate analysis,
# adapts to the virtualization technology, and offers robust, structured output.
#
# Changelog (v8):
# 1. Auto-Provisioning: The script now automatically detects and attempts to install
#    missing dependencies (fio, sysstat, virt-what) using the system's package manager.
# 2. No Fallbacks: Removed basic methods. 'fio' is now required for disk tests and
#    'mpstat' for CPU analysis to ensure measurement quality. Tests will fail if
#    tools cannot be installed.
# 3. Enhanced Robustness: Improved installation logic with permission checks.
# 4. Professional Tone: Maintained formal, objective, and professional tone.
#

# --- Safe Execution & Cleanup ---
set -eo pipefail
trap 'rm -f test_io.tmp fio_test_file.tmp' EXIT

# --- Global Variables & Default Settings ---
VERSION="8.0"
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
    echo "VPS Diagnostics Toolkit (v${VERSION})"
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  --disk-warn-mbps <val>   Set disk I/O warning threshold in MB/s (default: ${DISK_WARN_MBPS})."
    echo "  --mem-warn-mbps <val>    Set memory speed warning threshold in MB/s (default: ${MEM_WARN_MBPS})."
    echo "  --steal-warn-percent <val> Set CPU steal time warning threshold in percent (default: ${STEAL_WARN_PERCENT})."
    echo "  --skip-io                Skip the disk and memory I/O performance tests."
    echo "  --json                   Output results in JSON format."
    echo "  -h, --help               Show this help message."
}

# --- Core Check Functions ---

install_dependencies() {
    print_color "36" "[0/6] Dependency Auto-Installer"
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
        print_color "32" "All recommended diagnostic tools are already installed."
        RESULTS[dependencies]="OK"
        return
    fi

    print_color "33" "Attempting to auto-install missing tools: ${pkgs_to_install[*]}"
    local pm=""
    if command -v apt-get &>/dev/null; then pm="apt"; fi
    if command -v yum &>/dev/null; then pm="yum"; fi
    if command -v dnf &>/dev/null; then pm="dnf"; fi

    if [ -z "$pm" ]; then
        print_color "31" "Error: Could not detect package manager (apt/yum/dnf). Please install dependencies manually."
        exit 1
    fi
    
    local install_cmd=""
    if [ "$(id -u)" -eq 0 ]; then
        install_cmd=""
    elif command -v sudo &>/dev/null; then
        install_cmd="sudo"
    else
        print_color "31" "Error: This script requires root privileges or 'sudo' to install dependencies. Aborting."
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
    
    print_color "32" "Dependency installation process complete."
    RESULTS[dependencies]="installed_attempted"
}

check_virt_type() {
    print_color "36" "[1/6] Virtualization Technology Detection"
    if command -v systemd-detect-virt &>/dev/null; then
        VIRT_TYPE=$(systemd-detect-virt)
    elif command -v virt-what &>/dev/null; then
        VIRT_TYPE=$(virt-what)
    fi
    print_color "34" "Detected Virtualization: ${VIRT_TYPE}"
    RESULTS[virt_type]=$VIRT_TYPE
}

run_memory_test() {
    if [[ "$SKIP_IO" == true ]]; then print_color "33" "[2/6] Memory Performance Test (Skipped)"; return; fi
    print_color "36" "[2/6] Memory Performance Test"
    
    local test_path=""
    if [ -d /dev/shm ] && [ -w /dev/shm ]; then
        test_path="/dev/shm"
        print_color "32" "Method: 'dd' on /dev/shm (in-memory filesystem)."
    else
        test_path="/tmp"
        print_color "33" "Notice: /dev/shm unavailable, using /tmp. Results may be affected by disk speed."
    fi

    local speed_info
    if ! speed_info=$(LC_ALL=C dd if=/dev/zero of="${test_path}/test.tmp" bs=1M count=256 2>&1); then
        print_color "31" "Test failed: 'dd' command execution error."
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
    print_color "34" "Result: ${speed_mb} MB/s"
    if [ "$speed_mb" -lt "$MEM_WARN_MBPS" ] && [ "$test_path" == "/dev/shm" ]; then
        print_color "31" "Warning: Memory speed is below threshold (${MEM_WARN_MBPS} MB/s)."
    fi
}

run_disk_test() {
    if [[ "$SKIP_IO" == true ]]; then print_color "33" "[3/6] Disk I/O Performance Test (Skipped)"; return; fi
    print_color "36" "[3/6] Disk I/O Performance Test"
    
    if ! command -v fio &>/dev/null; then
        print_color "31" "Test Failed: 'fio' is required but not installed. Auto-install may have failed."
        RESULTS[disk_mbps]=-1
        return
    fi
    
    print_color "32" "Method: 'fio' benchmark (4k random write, direct I/O)."
    local fio_output speed_mb
    if ! fio_output=$(fio --name=test --ioengine=libaio --iodepth=64 --rw=randwrite --bs=4k --direct=1 --size=256M --numjobs=1 --runtime=10 --filename=fio_test_file.tmp --group_reporting 2>&1); then
         print_color "31" "Test failed: 'fio' command execution error."
         RESULTS[disk_mbps]=-1
         return
    fi
    speed_mb=$(echo "$fio_output" | grep -oP 'bw=\K[0-9.]+(?=MiB/s)' | awk '{printf "%.0f", $1}')

    RESULTS[disk_mbps]=$speed_mb
    print_color "34" "Result: ${speed_mb} MB/s"
    if [ "$speed_mb" -lt "$DISK_WARN_MBPS" ]; then
        print_color "31" "Warning: Disk I/O speed is below threshold (${DISK_WARN_MBPS} MB/s)."
    fi
}

check_kvm_features() {
    if [[ "$VIRT_TYPE" != "kvm" && "$VIRT_TYPE" != "qemu" ]]; then
      print_color "33" "[4/6] KVM-Specific Feature Check (Skipped, Not KVM)"
      RESULTS[balloon_driver]="not_applicable"
      RESULTS[ksm_enabled]="not_applicable"
      return
    fi
    
    print_color "36" "[4/6] KVM Feature: virtio_balloon Driver"
    if lsmod | grep -q virtio_balloon; then
        print_color "33" "Indicator: virtio_balloon driver is loaded."
        print_color "33" "This enables the host to dynamically reclaim memory, a capability for overselling."
        RESULTS[balloon_driver]="loaded"
    else
        print_color "32" "OK: virtio_balloon driver is not loaded."
        RESULTS[balloon_driver]="not_loaded"
    fi

    print_color "36" "[5/6] KVM Feature: Kernel Samepage Merging (KSM)"
    if [ -f /sys/kernel/mm/ksm/run ] && [ "$(cat /sys/kernel/mm/ksm/run)" -eq 1 ]; then
        print_color "33" "Indicator: KSM is enabled."
        print_color "33" "This memory-saving feature is commonly used in high-density virtualization."
        RESULTS[ksm_enabled]=true
    else
        print_color "32" "OK: KSM is not enabled."
        RESULTS[ksm_enabled]=false
    fi
}

run_cpu_steal_test() {
    print_color "36" "[6/6] CPU Steal Time Analysis"
    
    if ! command -v mpstat &>/dev/null; then
        print_color "31" "Test Failed: 'mpstat' is required but not installed. Auto-install may have failed."
        RESULTS[cpu_steal_percent]=-1
        return
    fi

    print_color "32" "Method: 'mpstat' analysis over 5 seconds (average)."
    local steal_avg
    steal_avg=$(mpstat -P ALL 1 5 | grep "Average" | awk '{print $NF}')
    
    RESULTS[cpu_steal_percent]=$steal_avg
    print_color "34" "Result: ${steal_avg}% average steal time."
    if (( $(echo "$steal_avg > $STEAL_WARN_PERCENT" | bc -l 2>/dev/null || echo "$steal_avg > $STEAL_WARN_PERCENT") )); then
        print_color "31" "Warning: CPU Steal Time is above threshold (${STEAL_WARN_PERCENT}%)."
    fi
}

# --- Main Execution Logic ---
main() {
    declare -A RESULTS
    parse_args "$@"
    
    if [[ "$JSON_OUTPUT" == false ]]; then
        print_color "33" "VPS Diagnostics Toolkit (v${VERSION})"
        print_color "0"  "================================================"
    fi

    install_dependencies
    check_virt_type
    run_memory_test
    run_disk_test
    check_kvm_features
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
        print_color "33" "Diagnostic Complete."
        print_color "35" "Disclaimer: These results are diagnostic indicators, not definitive proof of"
        print_color "35" "overselling. Correlate with your application's performance for a complete picture."
    fi
}

main "$@"
