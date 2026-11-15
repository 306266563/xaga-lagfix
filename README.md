# 澎湃OS2 无响应/卡顿优化 · 使用手册

`xaga-lagfix` —— 给 Redmi Note 11T Pro（xaga，6GB）的澎湃OS2 治卡顿和无响应。抖音划视频卡、切应用转圈、输入法等半天、隔三差五弹「无响应」，都是它管的范围。

装上之后不需要你做任何事。开机自动生效，之后每分钟核对一次，参数被系统改回去就补回来。

> 只写系统属性和 `/proc`、`/sys` 里的参数，不动系统分区。删掉模块重启，一切回到原样。

## 它做了什么

| 项目 | 改了什么 | 为什么 |
|---|---|---|
| **内存回收时机** | `extra_free_kbytes` 31 MB → 96 MB、`min_free_kbytes` 9 MB → 64 MB、`watermark_scale_factor` 1 → 20 | 内核保留内存原厂合计仅约 40 MB，空闲内存跌破 40 MB 才开始回收，这时应用只能自己同步等待，系统界面会卡在换入路径上、触摸长时间无响应。留出约 160 MB 让后台回收线程提前干活；再往上抬反而从应用嘴里抠内存，挤掉文件缓存 |
| **swappiness** | 保持 60 | 内存不够时优先压进 ZRAM，而不是直接杀进程。但 100 会连 SystemUI、输入法、system_server 这些一操作就要用的进程一起换出去，触摸、弹键盘时主线程只能等 zram 解压，5 秒超时就是无响应 |
| **ZRAM** | 系统默认 4GB → 6GB，与物理内存 1:1 | 内存不够时先用压缩池顶住，不至于直接杀进程 |
| **换页预读** | `page-cluster` 3 → 0 | 换入页在 ZRAM 里是散落的，预读 8 页通常只有 1 页真用上，剩下 7 页白解压 |
| **内存碎片** | `compaction_proactiveness` 20、`extfrag_threshold` 800 | 空闲时后台整理碎片，少做无效整理烧 CPU |
| **文件缓存** | `vfs_cache_pressure` 50 → 30 | 少回收 inode/dentry 缓存，切应用、滑列表快一点 |
| **IO 与回写** | mq-deadline、`nr_requests` 256、dirty 回写水位 | UFS 攒批量回写，减少小 IO 抖动 |
| **后台 dex2oat** | `bg-dexopt` / `boot` / `install` 等六项改成 `verify` | 关掉后台空闲重编译。之前日志里 dex2oat64 抢内存抢到 SIGABRT 崩过一次 |

> lmkd 走原厂逻辑。`system.prop` 里那几条 `ro.lmk.*` 保留但不起作用——lmkd 属 `class core`，开机 4.6 秒就已读完属性，而模块要等到 post-fs-data 阶段（约 60 秒后）才注入。

另外还有两件不在参数层面的事：

- **守护进程**常驻，每分钟核一遍上面这些参数。小米的内存 daemon 会在运行中把 swappiness 往高里拉，靠它压回去
- **一键自检**：管理器里点模块卡片的「执行」，会当场把所有参数核一遍，不对的立刻改，并按三个视角报告谁在杀进程（MIUI / 内核 / AMS）、谁被反复拉起、谁的存活时间短得离谱

## 装

管理器（KernelSU / APatch）→ 模块 → 本地安装 → 选 zip → 重启。

重启后等一分钟，让守护先把 ZRAM 重建完。

## 装完怎么确认它在干活

管理器里点模块卡片的「执行」按钮，最省事。会打印成这样：

```
======== xaga_lagfix v2.18 ========
---- 参数 ----
  swappiness        60  [OK]
  sys.lmk.minfree   38400:0,64000:100,...  [系统自管]
  zram disksize     6442450944  [OK]
  压缩算法          lzo lzo-rle [lz4] zstd
  swap 占用         3714940 / 6291452 kB  (59%)
---- 守护 ----
  运行中(心跳 40s 前)  [OK]
---- 内存 ----
  MemTotal:      5588580 kB
  MemFree:       38176 kB
  MemAvailable:  1088000 kB
  开机累计        pswpin=15848291 pswpout=20981050 pgmajfault=16831250 ...
---- 压力 PSI (some/full 的 avg10 avg60 avg300) ----
  memory  some  27.85 22.09 21.80
  memory  full  10.11 8.54 8.15
  cpu     some  24.50 23.92 22.19
  io      some  8.76 8.46 10.88
  io      full  3.34 3.10 3.97
---- 统计窗口 ----
  events 缓冲区覆盖约 222 分钟(重启后清零), 下面所有次数都在此窗口内
---- 被杀: MIUI 视角 (killinfo) ----
  共 4211 条, 被杀最多:
       1384 com.miui.screenrecorder
        459 com.android.camera
---- 被杀: 内核视角 (lowmemorykiller) ----
        108 com.miui.screenrecorder
         39 com.tencent.mm:push
---- 被杀: AMS 视角 (am_kill) ----
  共 28 次
  按原因:
         12 MiuiMemoryService(recent-provider)
          8 MiuiMemoryService(started-services)
---- 拉起与存活 ----
  被拉起最多:
       1385 com.miui.screenrecorder
  短命进程(拉起后 30 秒内就被杀, 按次数):
    com.miui.screenrecorder                  短命 1307 次, 最短 0.1 秒
    com.tencent.mm:push                      短命 407 次, 最短 1.4 秒
---- ANR ----
  次数: 0
---- 最近日志 ----
  [10-30 18:30:55] === guard start (v2.17) ===
================================
```

也能自己跑命令核：

```sh
getprop sys.lmk.use_minfree_levels   # 应该是 true
getprop sys.lmk.minfree_levels       # 值由系统自己给，模块不干预
cat /proc/sys/vm/swappiness          # 应该是 60
cat /proc/swaps                      # Size 应该是 6291452
```

`Size` 是 6291452（约 6GB）就说明 ZRAM 拉到位了。`Used` 会随时间涨，那是在用压缩池，正常。

## 出问题时

| 现象 | 怎么办 |
|---|---|
| 点「执行」显示 `zram disksize` 不是 6442450944 | ZRAM 没重建成功。运行中重建要把压缩页全解回物理内存，内存紧张时会卡死，所以模块故意不在运行中动手。**重启一次**即可 |
| 点「执行」显示「守护进程：无心跳文件」 | 守护被系统清理了。点「执行」会自动重新拉起，约 45 秒后生效 |
| swappiness 又变了 | 小米的 daemon 改的。等一分钟守护会压回去；急的话点「执行」 |
| 还是卡 | 先看「执行」输出里的「短命进程」。某个应用被拉起上千次、存活不到 1 秒，是它被系统反复搓，问题不在参数 |
| 三个「被杀」视角该看哪个 | **内核视角那节才是模块调参能碰的一侧**。MIUI killinfo 和 AMS am_kill 记的是系统自己的决策，模块改不了；MIUI 那节次数最多是常态 |
| 录屏、小米互传老是被杀 | 控制中心那两个磁贴被 SystemUI 反复拉起，起来就被 MIUI 杀掉再拉起（实测 3.7 小时 1384 次）。把磁贴移出快捷设置就行 |
| 开机慢、App 第一次点开慢 | 6GB 的常态，模块解决不了。dex2oat 已经关了，剩下的靠关自启动 |

> 模块不管的部分要说清楚：它治不了第三方 App 自己占着内存不放、自己互相唤醒。QQ 加微信常驻就是 1.4GB，抖音刷视频本身还要 1GB 上下，6GB 物理内存是这个机器的硬约束。

## 卸载

管理器里移除模块，重启。不改系统分区，卸载后完全恢复。

## 文件都在哪

```
module.prop          模块信息
system.prop          开机注入的系统属性
post-fs-data.sh      开机早期写 /proc、/sys（一次）
service.sh           用 setsid 拉起守护，然后退出
guard.sh             守护本体：重建 ZRAM、常驻核对参数、写心跳
lib.sh               公共函数，上面三个脚本共用
action.sh            「执行」按钮跑的就是它
uninstall.sh         卸载时清理日志和心跳文件
```

运行日志在 `/data/local/tmp/xaga_lagfix.log`，超过 4KB 自动裁到 200 行。

> `service.sh` 里必须用 `setsid` 拉起 `guard.sh`。直接 `( ... ) &` 的话，APatch / KernelSU 在脚本退出时会把这个进程组一起清掉，守护无法存活到开机之后。

## 开发

- SakuraTears（306266563）：需求、真机测试、日志采集
- 代码与日志分析由 DeepSeek 协助完成

## 许可

GPL-3.0
