#!/usr/bin/env bash

# 下载最新的脚本到临时文件
temp_script=$(mktemp)
curl -s https://raw.githubusercontent.com/jasonzhu1207/memoryCheck/main/memory_check.sh -o $temp_script

# 确保脚本是可执行的
chmod +x $temp_script

# 执行下载的脚本
bash $temp_script

# 删除临时文件
rm $temp_script
