#!/system/bin/sh
# service 阶段: 只负责用 setsid 拉起 guard.sh 后退出。
# 不能直接 ( ... ) & —— APatch/KSU 在脚本结束后会清理其子进程组,
# 后台逻辑会被连带杀掉(实测只剩 start 日志, 没有 sleep 循环)。

MODDIR=${0%/*}

[ -f "$MODDIR/guard.sh" ] && setsid sh "$MODDIR/guard.sh" >/dev/null 2>&1 &

exit 0
