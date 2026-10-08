#!/system/bin/sh

MODDIR=${0%/*}

# KernelSU 管理器中的“执行”按钮：只打开目标应用，由前台监听器触发脚本。
"$MODDIR/bin/control.sh" open

