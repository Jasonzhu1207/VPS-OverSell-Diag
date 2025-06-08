# VPS 超售检测工具（VPS-OverSell-Diagnostics）

一个轻量级、智能化的VPS性能诊断脚本，旨在提供专业、客观的性能评估与超售指标分析。

### 功能特性

* **一键启动**: 自动下载并执行，无需手动配置。
* **依赖自动配置**: 自动检测并尝试安装`fio`, `sysbench`等专业诊断工具。
* **智能识别**: 自动检测KVM/LXC等虚拟化技术和SSD/HDD硬盘类型，执行最合适的测试。
* **深度测试模式**: 支持`--full-test`，使用`sysbench`和`fio`进行全面的内存与磁盘I/O基准测试。
* **关键指标分析**: 检测CPU窃取时间、`virtio_balloon`驱动和KSM内存合并等超售相关技术。
* **JSON输出**: 支持`--json`参数，便于自动化集成。

### 🚀 使用方法

**默认执行深度测试:**
```bash
bash <(curl -s https://raw.githubusercontent.com/jasonzhu1207/VPS-OverSell-Diag/main/main.sh)
```

### 🛠️ 自定义参数

* `--full-test`: (默认启用) 执行更全面的(但更耗时)内存和磁盘性能测试。
* `--skip-io`: 跳过耗时较长的磁盘和内存性能测试。
* `--json`: 将所有诊断结果以JSON格式输出。
* `--disk-warn-mbps <值>`: 自定义磁盘性能的警告阈值 (MB/s)。
* `--mem-warn-mbps <值>`: 自定义内存速度的警告阈值 (MB/s)。
* `--steal-warn-percent <值>`: 自定义CPU窃取时间的警告阈值 (%)。
* `-h`, `--help`: 显示帮助信息。

