#!/system/bin/sh

MODDIR=${0%/*}

# KernelSU 管理器中的“执行”按钮：打开目标应用。
# 当应用随后请求 Root 时，监听器会按配置触发脚本。
"$MODDIR/bin/control.sh" open

