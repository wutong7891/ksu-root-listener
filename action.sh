#!/system/bin/sh

MODDIR=${0%/*}

# KernelSU 管理器中的“执行”按钮：打开目标应用，等待输入配置数字后触发。
"$MODDIR/bin/control.sh" open

