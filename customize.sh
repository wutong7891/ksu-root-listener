#!/system/bin/sh

SKIPUNZIP=0

ui_print "- 正在安装 KSU Root监听与 Root 控制台"
ui_print "- 默认关闭监听，请安装后进入模块 WebUI 配置"
ui_print "- 应用前台监听可独立工作；Root 事件记录需要内核和 ksud 支持 sulog"

STATE_DIR="/data/adb/ksu_app_watcher"
CONFIG="$STATE_DIR/config"
mkdir -p "$CONFIG" "$STATE_DIR/logs"

# 从早期版本的模块目录迁移配置，之后升级模块不会丢失设置。
for name in enabled package script interval events cooldown preinput; do
  if [ ! -f "$CONFIG/$name" ] && [ -f "$MODPATH/config/$name" ]; then
    cp -f "$MODPATH/config/$name" "$CONFIG/$name"
  fi
done

[ -f "$CONFIG/enabled" ] || echo 0 > "$CONFIG/enabled"
[ -f "$CONFIG/package" ] || echo com.example.app > "$CONFIG/package"
[ -f "$CONFIG/script" ] || echo "$MODPATH/scripts/target.sh" > "$CONFIG/script"
[ -f "$CONFIG/interval" ] || echo 2 > "$CONFIG/interval"
[ -f "$CONFIG/events" ] || echo sucompat,ioctl_grant_root > "$CONFIG/events"
[ -f "$CONFIG/cooldown" ] || echo 2 > "$CONFIG/cooldown"
[ -f "$CONFIG/preinput" ] || : > "$CONFIG/preinput"
chmod 0700 "$STATE_DIR" "$CONFIG" "$STATE_DIR/logs"
chmod 0600 "$CONFIG"/* 2>/dev/null

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
set_perm_recursive "$MODPATH/scripts" 0 0 0755 0755

