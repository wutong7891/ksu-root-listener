#!/system/bin/sh

# 把你要执行的逻辑写在这里，或在 WebUI 中填写另一个绝对路径。
# 该脚本由 root 执行，当前工作目录为 /。

echo "target.sh 已执行"
echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "用户: $(id)"
echo "目录: $(pwd)"
echo "事件: ${KSU_SULOG_TYPE:-手动执行}"
echo "来源应用: ${KSU_SULOG_PACKAGE:-未知}"
echo "来源 UID: ${KSU_SULOG_UID:-未知}"
echo "来源进程: ${KSU_SULOG_COMM:-未知}"

