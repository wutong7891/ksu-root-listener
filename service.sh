#!/system/bin/sh

MODDIR=${0%/*}

# late_start 阶段启动 Root 守护器。监听器意外退出时自动拉起；模块被禁用、
# 标记移除或目录消失后守护器自行结束。监听器内部的原子锁会阻止重复实例。
(
  while [ -d "$MODDIR" ] && [ ! -f "$MODDIR/disable" ] && [ ! -f "$MODDIR/remove" ]; do
    "$MODDIR/bin/watcher.sh"
    sleep 3
  done
) </dev/null >/dev/null 2>&1 &

