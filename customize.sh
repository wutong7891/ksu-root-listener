#!/system/bin/sh

SKIPUNZIP=0

ui_print "- 正在安装 KSU Root监听与 Root 控制台"
ui_print "- 默认关闭监听，请安装后进入模块 WebUI 配置"
ui_print "- Root监听需要内核和 ksud 支持 sulog 功能"

mkdir -p "$MODPATH/config" "$MODPATH/logs"

[ -f "$MODPATH/config/enabled" ] || echo 0 > "$MODPATH/config/enabled"
[ -f "$MODPATH/config/package" ] || echo com.example.app > "$MODPATH/config/package"
[ -f "$MODPATH/config/script" ] || echo "$MODPATH/scripts/target.sh" > "$MODPATH/config/script"
[ -f "$MODPATH/config/interval" ] || echo 2 > "$MODPATH/config/interval"
[ -f "$MODPATH/config/events" ] || echo sucompat,ioctl_grant_root > "$MODPATH/config/events"
[ -f "$MODPATH/config/cooldown" ] || echo 2 > "$MODPATH/config/cooldown"
[ -f "$MODPATH/config/preinput" ] || : > "$MODPATH/config/preinput"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
set_perm_recursive "$MODPATH/scripts" 0 0 0755 0755

