#!/system/bin/sh
# 公共函数库 —— 由 service.sh / guard.sh / action.sh 通过 . 引入
# 提供: 常量、日志、日志裁剪、幂等写值(put/setp)、apply_all
#
# 命名约定: 每个 WANT_* 常量的名字 = 对应 vm 参数名转大写、"-" 换 "_"。
# 自测脚本第 9 段依赖这个约定做两端取值比对，改名时两边要一起改。

LOG=/data/local/tmp/xaga_lagfix.log
HB=/data/local/tmp/xaga_lagfix.hb
LOG_MAX=4096

# ZRAM 6GB, 与物理内存 1:1
ZRAM_SIZE=6442450944

# ---------- 内存回收与回写 ----------
# 内存不够优先压进 ZRAM, 而非直接杀进程(daemon 会把它往高里拉, 这里持续纠回)
# 2026-11-15 由 100 降到 60: 100 时内核把 SystemUI/输入法/system_server 也当冷页换出去,
# 触摸、弹键盘这些一操作就要用的场景, 主线程只能 D 状态等 zram 解压, 5 秒超时 ANR
# (11-15 10:57 抖音 trace: VmSwap 756104 kB, 主线程 5 个 D 状态)。
# 降到 60 后同步回收占比 38% -> 3.6%, 等内存时间 10.16% -> 1.00%。
# 尚未验证: 60 与 100 的 A/B 对照没做成(两次测试起跑线差 473 MB, 均 0 ANR),
# 目前依据是机制分析而非受控实验; 若体感变差, 改回 100 即可。
WANT_SWAPPINESS=60
# kswapd 唤醒水位差 = MemTotal * 本值 / 10000
# 原厂值 1 时水位差约 5 MB, kswapd 几乎无提前量, 回收全压在分配方身上(direct reclaim)
WANT_WATERMARK_SCALE_FACTOR=20
# 空闲时后台整理碎片, 缓解高 order 连续块枯竭
WANT_COMPACTION_PROACTIVENESS=20
# 保底空闲页, 减少分配路径上的直接回收
WANT_MIN_FREE_KBYTES=65536
# kswapd 提前介入的额外余量(叠加在 low 水位上)。
# 实测设备上 MIUI 值 31134 与本文件 min_free_kbytes 相加仅约 40 MB, MemFree 掉到
# 38 MB 才开始回收, 分配方只能自己做 direct reclaim —— SystemUI 因此卡在内核
# lock_page_maybe_drop_mmap(STAT=D)、输入分发超时黑屏。抬到 192 MB 让 kswapd 提前干活。
# 2026-11-15 由 192 MB 降到 96 MB: 192 MB 时 MemAvailable 比上一版低 150-700 MB,
# 保留内存是从应用嘴里抠的, 挤掉 page cache 反而让换出更狠。96 MB 仍是原厂 31 MB 的三倍。
WANT_EXTRA_FREE_KBYTES=98304
# 值越小越舍不得回收 inode/dentry 缓存
WANT_VFS_CACHE_PRESSURE=30
# 值越大越少尝试碎片整理(避免无效 compaction 烧 CPU)
WANT_EXTFRAG_THRESHOLD=800
# swap 少预读: 换入页在 zram 中散落, 预读 8 页多为无效解压
WANT_PAGE_CLUSTER=0
# 脏页回写水位: 攒批量回写, 减少小 IO 抖动
WANT_DIRTY_RATIO=20
WANT_DIRTY_BACKGROUND_RATIO=10
WANT_DIRTY_EXPIRE_CENTISECS=6000
WANT_DIRTY_WRITEBACK_CENTISECS=1500
# 减少 malloc 失败崩溃(dex2oat 曾因此 SIGABRT)
WANT_OVERCOMMIT_MEMORY=1
# 允许回收 unevictable 页, 少唤醒 compaction
WANT_COMPACT_UNEVICTABLE_ALLOWED=1

log() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG" 2>/dev/null; }

# 日志超 LOG_MAX 字节时裁到最近 200 行
trim_log() {
  [ -f "$LOG" ] || return 0
  # 强制重启后 f2fs 可能把日志恢复成一整段 NUL(长度对、内容全零),
  # 该内容直接输出为空白行, 需先剥离
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
# 文件不存在时静默跳过(不同内核暴露的旋钮不同, 缺项由 selftest 的接口清单断言负责)
# 重定向顺序: 必须先 2>/dev/null 再 > 文件。文件不可写时 shell 自己的报错发生在
# 重定向建立阶段, 那时 2>/dev/null 还没生效, 会绕过它漏到 stderr
# $1=文件路径 $2=期望值 $3=名称
put() {
  [ -e "$1" ] || return 0
  cur=$(cat "$1" 2>/dev/null)
  [ "$cur" = "$2" ] && return 0
  echo "$2" 2>/dev/null > "$1"
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

  # 以下各项原先只在 post-fs-data 阶段写一次, 失败无人核对(实测 page-cluster 丢过一次)。
  # 现全部由本函数每分钟兜底, 每处写入都带回读校验。
  put /proc/sys/vm/watermark_scale_factor "$WANT_WATERMARK_SCALE_FACTOR" watermark_scale_factor
  put /proc/sys/vm/compaction_proactiveness "$WANT_COMPACTION_PROACTIVENESS" compaction_proactiveness
  put /proc/sys/vm/min_free_kbytes "$WANT_MIN_FREE_KBYTES" min_free_kbytes
  put /proc/sys/vm/extra_free_kbytes "$WANT_EXTRA_FREE_KBYTES" extra_free_kbytes
  put /proc/sys/vm/vfs_cache_pressure "$WANT_VFS_CACHE_PRESSURE" vfs_cache_pressure
  put /proc/sys/vm/extfrag_threshold "$WANT_EXTFRAG_THRESHOLD" extfrag_threshold
  put /proc/sys/vm/page-cluster "$WANT_PAGE_CLUSTER" page-cluster
  put /proc/sys/vm/dirty_ratio "$WANT_DIRTY_RATIO" dirty_ratio
  put /proc/sys/vm/dirty_background_ratio "$WANT_DIRTY_BACKGROUND_RATIO" dirty_background_ratio
  put /proc/sys/vm/dirty_expire_centisecs "$WANT_DIRTY_EXPIRE_CENTISECS" dirty_expire_centisecs
  put /proc/sys/vm/dirty_writeback_centisecs "$WANT_DIRTY_WRITEBACK_CENTISECS" dirty_writeback_centisecs
  put /proc/sys/vm/overcommit_memory "$WANT_OVERCOMMIT_MEMORY" overcommit_memory
  put /proc/sys/vm/compact_unevictable_allowed "$WANT_COMPACT_UNEVICTABLE_ALLOWED" compact_unevictable_allowed

  # lmkd 阈值不写: sys.lmk.minfree_levels 由系统自己动态重算(实测开机后每分钟一次),
  # 模块写回去只会来回抢写。
  # ro.lmk.* 是开机属性, lmkd 属 class core、boottime 约 4.6 秒就已启动,
  # 而模块 system.prop 在 post-fs-data 阶段(约 60 秒后)才注入, 改这些值不生效。
  # 注意: system.prop 里仍写着 ro.lmk.use_minfree_levels / 抬高的 minfree_levels,
  # 按上述时序对运行中的 lmkd 没有作用(实测设备上仍是原厂 false + 原厂六档)。
  # 真正运行期生效的是本函数的 /proc/sys/vm/* 与 sys.mem.* 属性。
}
