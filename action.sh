#!/system/bin/sh

MODDIR=${0%/*}

# KernelSU 管理器中的“执行”按钮：打开目标应用；空数字按 v11 前台触发，
# 配置数字后等待输入精确匹配触发。
"$MODDIR/bin/control.sh" open

