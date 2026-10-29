#!/system/bin/sh
# 公共函数库 —— 由 service.sh / guard.sh / action.sh 通过 . 引入
# 提供: 常量、日志、日志裁剪、幂等写值(put/setp)、apply_all

LOG=/data/local/tmp/xaga_lagfix.log
HB=/data/local/tmp/xaga_lagfix.hb
LOG_MAX=4096

# ZRAM 6GB, 与物理内存 1:1
ZRAM_SIZE=6442450944
# 原厂 100 会被 daemon 拉回 120, 压到 60 减少主动换出
WANT_SWAPPINESS=60

log() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG" 2>/dev/null; }

# 日志超 LOG_MAX 字节时裁到最近 200 行
trim_log() {
  [ -f "$LOG" ] || return 0
  # 强制重启后 f2fs 可能把日志恢复成一整段 NUL(长度对、内容全零),
  # 这种内容 tail 出来就是满屏空白, 先剥掉
  nb=$(wc -c < "$LOG" 2>/dev/null)
  [ -z "$nb" ] && return 0
  nz=$(tr -d '\000' < "$LOG" 2>/dev/null | wc -c)
  if [ "$nb" != "$nz" ]; then
    tr -d '\000' < "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
    log "日志含 NUL, 已剥离 ($nb -> $nz 字节)"
  fi
  size=$(wc -c < "$LOG" 2>/dev/null)
  [ -z "$size" ] && return 0
  [ "$size" -lt "$LOG_MAX" ] && return 0
  tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
}

# 写 sysfs/proc 值, 仅当值变化; 写后回读校验
# $1=文件路径 $2=期望值 $3=名称
put() {
  cur=$(cat "$1" 2>/dev/null)
  [ "$cur" = "$2" ] && return 0
  echo "$2" > "$1" 2>/dev/null
  now=$(cat "$1" 2>/dev/null)
  if [ "$now" = "$2" ]; then
    log "$3: $cur -> $now"
  else
    log "$3: $cur -> $2 (write failed, now=$now)"
  fi
}

# 写系统属性, 仅当值变化; 写后回读校验
# $1=属性名 $2=期望值
setp() {
  cur=$(getprop "$1" 2>/dev/null)
  [ "$cur" = "$2" ] && return 0
  setprop "$1" "$2" 2>/dev/null
  now=$(getprop "$1" 2>/dev/null)
  if [ "$now" = "$2" ]; then
    log "$1: $cur -> $now"
  else
    log "$1: $cur -> $2 (write failed, now=$now)"
  fi
}

# 应用一次全部参数(幂等)
# $1=allow_zram_rebuild  1=允许重建 ZRAM(仅开机首次)  其他=只检查不动手
apply_all() {
  allow_zram=${1:-0}

  # ZRAM 6GB (1:1)
  if [ -e /sys/block/zram0 ]; then
    cur=$(cat /sys/block/zram0/disksize 2>/dev/null)
    if [ "$cur" != "$ZRAM_SIZE" ]; then
      if [ "$allow_zram" = "1" ]; then
        # 必须先 swapoff 摘下来才能改大小(否则 Device or resource busy)
        swapoff /dev/block/zram0 2>/dev/null
        echo 1 > /sys/block/zram0/reset 2>/dev/null
        echo "$ZRAM_SIZE" > /sys/block/zram0/disksize 2>/dev/null
        mkswap /dev/block/zram0 2>/dev/null
        swapon /dev/block/zram0 2>/dev/null
        log "zram disksize: $cur -> $(cat /sys/block/zram0/disksize 2>/dev/null)"
      else
        # 运行中不重建: swapoff 要把压缩页全解回物理内存, 内存紧张时会卡死甚至 OOM。
        log "WARN zram disksize=$cur (期望 $ZRAM_SIZE), 运行中不自动重建, 需要时请重启"
      fi
    fi
  fi

  # swappiness 与源头属性(daemon 读这两个决定要不要拉回 120)
  put /proc/sys/vm/swappiness "$WANT_SWAPPINESS" swappiness
  setp sys.mem.swappiness_on_launcher "$WANT_SWAPPINESS"
  setp sys.mem.swappiness_on_start "$WANT_SWAPPINESS"

  # lmkd 阈值不写: sys.lmk.minfree_levels 由系统自己动态重算(实测开机后每分钟一次),
  # 模块写回去只会来回抢写。lmkd 的判据交给 ro.lmk.use_minfree_levels 与 PSI。
}
