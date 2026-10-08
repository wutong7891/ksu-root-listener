#!/system/bin/sh

MODDIR=${0%/*}

# late_start 阶段启动常驻监听器；监听器内部有 PID 锁，避免重复运行。
nohup "$MODDIR/bin/watcher.sh" </dev/null >/dev/null 2>&1 &

