#!/system/bin/sh
# 卸载时清理模块留下的文件
# 参数本身(ZRAM / 属性)重启后自动恢复系统默认, 无需处理

rm -f /data/local/tmp/xaga_lagfix.log 2>/dev/null
rm -f /data/local/tmp/xaga_lagfix.log.tmp 2>/dev/null

exit 0
