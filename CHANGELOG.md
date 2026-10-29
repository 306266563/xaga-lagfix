# 更新日志

> 每个版本的改动都记在这里。模块 zip 内不含本文件。

## v2.15 - 2026-10-29

### 修复
- 修复前台被内存回收拖住导致无响应的问题。此前版本按压力判据回收内存，实测微信、QQ 各出现一次输入 5 秒无响应
- lmkd 恢复按内存水位回收，并提高各档阈值，让系统更早开始温和回收 —— 原厂后两档阈值在 6GB 机器上到不了，等于失效
- 内存不足时优先使用压缩内存，不再直接结束进程
- 恢复换页预读参数，减少压缩内存环境下的换页抖动

### 改进
- 后台保活能力下降，微信、QQ 在后台更容易被系统清理，换取前台不再被拖住

## v2.14 - 2026-10-29

### 修复
- 修复并发执行自检时临时文件互相覆盖的问题
- 修复断电重启后自检面板显示错误的统计时长（曾出现「覆盖约 29887726 分钟」）
- 修复自检误判守护进程仍在运行的问题 —— 原先的匹配方式会把执行脚本的 shell 自身也算进去
- 修复卸载后残留心跳文件与临时文件的问题

### 改进
- 删除四个不生效的后台进程属性 —— 系统实际运行值被 MIUI 自己的配置覆盖，另三个是旧版本 Android 的参数，当前系统不再读取
- 精简脚本注释与模块简介

## v2.13 - 2026-10-29

### 新增
- 自检面板补上「谁在杀进程」的三个视角：MIUI 的 killinfo、内核 lowmemorykiller、AMS 的 am_kill —— 实测同一批进程被 MIUI 杀掉的次数远多于被内核杀掉的次数，只看内核视角会误判
- 新增 PSI 压力表：memory / cpu / io 的 some 与 full，各带 avg10 / avg60 / avg300
- 新增进程存活时长统计：把进程启动与结束按 pid 配对，列出「拉起后 30 秒内就被杀」的进程与最短存活时间
- 新增内存与换页累计、ANR 计数、日志缓冲区覆盖窗口
- 新增 zram 压缩算法显示

### 改进
- 自检时把系统日志一次性落盘再统一统计，不再反复调用 logcat
- 统计窗口改为按日志首尾行计算，避开开头的分隔符

## v2.12 - 2026-10-29

### 修复
- 修复进程被杀统计漏报的问题 —— 原先只读日志缓冲区最后一段，日志量大时会把恶性循环误报成「无明显循环」

### 改进
- 不再写运行期的 lmkd 阈值 —— 该值由系统按实时压力动态重算，模块每分钟写回原厂值属于来回抢写
- 自检输出改为按「参数 / 守护 / 循环 / 最近日志」分组，swap 只报已用与总量，新增「被拉起最多」统计
- 去掉换页预读参数的写入，该参数实测未生效

## v2.11 - 2026-10-28

### 修复
- lmkd 阈值恢复原厂六档，修正单位误判（页被当成 MB）
- lmkd 改用压力判据，不再死守内存水位
- 自检面板版本号同步为 v2.11

### 改进
- swappiness 由 100 调整为 60

## v2.10 (2026-10-27)
- 恢复 v2.6 的注释风格：每个配置项前面都有一句中文，说明它是干嘛的
  - `system.prop`：四个分组标题恢复（lmkd 阈值 / swappiness / 后台进程 / 权限编译 / 渲染输入），`minfree_levels` 补页数换算，逐项说明 `enhance_batch_kill`、`use_minfree_levels`、`kill_timeout_ms`、`bg_apps_limit`、`bservice_*`、`fservice_limit`、六条 `pm.dexopt.*`、三条渲染项
  - `post-fs-data.sh`：九个 `/proc/sys/vm/*` 参数和两个 UFS 参数逐条标注作用
  - `lib.sh`：常量 `LOG` / `HB` / `ZRAM` / `SWAP` / `LMK` 各标明用途；zram 重建五步加行内注释（为什么必须先 swapoff、为什么必须 mkswap）
- 包体 4033 → 5502 字节

## v2.9 (2026-10-27)
- 注释再压：每条只留一句，删掉「参数：」「职责：」这类标签式和解释性长句；`post-fs-data.sh` 的分组注释缩成「内存」「UFS」，`system.prop` 头部两行并成一行
- README 重写：去掉「适用/原理」的冒号标签开头、「做了什么」改成「改了什么」，验证代码块里的行内注释删掉，「已知情况」改成「注意」，正文 56 → 52 行但信息不减
- `module.prop` 的 description 改短：「为 … 定制。校正…、接管…、拉满…、优化…，持久化守护与一键自检」→「xaga 6GB 澎湃OS2 专用。校正 lmkd 阈值、固定 swappiness、zram 拉到 6GB、关后台 dex2oat、调 UFS IO，减少无响应和掉帧。」
- 包体 4439 → 4033 字节

## v2.8 (2026-10-27)
- 注释统一改为陈述句：去掉「必须」「注意」「职责」这类祈使口吻，只写事实
- 清除冗余代码：
  - `lib.sh` 的 `trim_log` 删掉多余的 `[ -f "$LOG" ] || return`（后面 `wc -c` 的 `|| echo 0` 已覆盖文件不存在的情况）
  - `lib.sh` 的 `apply_all` 把 `[ -e /sys/block/zram0 ]` + 读 disksize 的两层判断合并为「读不到就是空」，少一层嵌套
- 修正 `action.sh` 的误报：原来无论写入是否成功都显示 `(已修正)`，现在写后回读，失败显示 `(修正失败)`

## v2.7 (2026-10-27)
- 注释精简：脚本里原本大量「为什么这么写」的解释性段落改为只标记真正的坑（如 `service.sh` 的 setsid 原因、`lib.sh` 的运行中不重建 zram）；去掉对着读者说话的口吻和满屏分隔线
- 代码压缩（总行数 352 → 207，zip 7632 → 4377 字节）：
  - `action.sh` 148 → 64 行：去掉每项「[OK] / [已修正] / [失败]」的多分支 echo，统一成「读值 → 不一致就修 → 打一行」，状态靠值本身和 `(已修正)` 后缀表达
  - `lib.sh` 84 → 57 行：`put` / `setp` 合并成「写后回读、不一致才记一条」，变量名缩短为 `ZRAM` / `SWAP` / `LMK`
  - `post-fs-data.sh` 32 → 22 行：去掉每行的 `|| true`（有 `2>/dev/null` 就够），分区循环变量改 `q`
  - `guard.sh` 24 → 19 行：用 `cd "${0%/*}" && . ./lib.sh` 取代 `MODDIR`
  - `system.prop` 40 → 29 行：段标题合并，只留真正需要解释的三处
- `uninstall.sh` 补删心跳文件
- 行为不变，参数值与 v2.6 完全一致

## v2.6 (2026-10-26)
- `action.sh` 新增「反复复活进程」检测：从 logcat 统计被 lmkd 杀掉 ≥5 次的进程并列出（近期实测 `com.miui.screenrecorder` 42 次、`com.miui.mishare.connectivity` 31 次，根因是 SystemUI 的控制中心磁贴反复拉起 → lmkd 又杀，形成死循环）
- 删除 `ro.config.low_ram=false`：实测 fp9 props 该值本来就是 false，写入无效（与之前删的 `debug.hwui.disable_vsync=false` 同性质）
- **修正模块介绍里的虚构功能**：原描述含「压进程冻结卡顿」，但模块从未实现过任何冻结/冻结抑制逻辑（`ro.control_privapp_permissions=log` 是 privapp 权限违规降级为记日志，与冻结无关），该条为早期写介绍时的想当然，已删
- 介绍补上 `action.sh` 的「一键自检」能力，改为「持久化守护＋一键自检」
- 注释精简：`system.prop` 56→40 行、`post-fs-data.sh` 35→32 行、`lib.sh`、`guard.sh`、`service.sh` 去掉重复解释，只保留「为什么这么写」的关键信息

## v2.5 (2026-10-26)
- **修复守护进程根本没启动（根因）**：APatch/KSU 在 `service.sh` 主流程结束后会清理其子进程组，原来的 `( ... ) &` 写法被连带杀掉。实测证据：`ps -A -o PID,PPID,ARGS | grep sleep` 只能查到 `sleep 1800`（别的东西），查不到守护的 `sleep 60`；同时日志里有 `=== service start ===` 和参数写入记录，但之后没有任何循环痕迹
- 修法：拆成三段——`lib.sh`（公共函数：常量/日志/裁剪/put/setp/apply_all）、`guard.sh`（守护主体：sleep 45 → 首次 apply_all 1 → while 循环）、`service.sh`（只负责 `setsid sh guard.sh &` 然后立即退出）。setsid 让守护成为独立会话 leader，脱离被连带清理的进程组
- 新增心跳文件 `/data/local/tmp/xaga_lagfix.hb`：guard.sh 每轮写时间戳，`action.sh` 据「距上次心跳多少秒」判断守护存活，比 `ps` 匹配可靠
- `action.sh` 升级：守护被判定已停止时，自动用 setsid 重新拉起（约 45 秒后生效），不必重启手机

## v2.4 (2026-10-26)
- 新增 `action.sh`：管理器里模块卡片的「执行」按钮，一键重新应用参数并打印当前状态（swappiness / lmkd 阈值 / zram disksize / swap 实际占用 / 守护是否在跑 / 最近 8 行日志）
- 新增 `uninstall.sh`：卸载时清理 `/data/local/tmp/xaga_lagfix.log`（属性与 ZRAM 重启后自动恢复，无需处理）
- 日志裁剪从「每 360 次检查裁一次」改为**按体积**（超过 4096 字节裁到最近 200 行），避免参数被反复改时日志暴涨
- `put()` / `setp()` 增加写入结果校验：写后回读，若与期望值不符则记 `(write failed, now=X)`，不再把"写失败"伪装成"无变化"
- **ZRAM 重建移出运行期**：`apply_all` 增加 `allow_zram` 参数，只有开机首次调用时才允许 swapoff 重建；守护循环里若发现 disksize 不符，只写一条 `WARN` 不自动重建（满 6GB swap 时 swapoff 需把压缩页全解回物理内存，内存不足会卡死数分钟甚至 OOM 连环杀）

## v2.3 (2026-10-26)
- 删除 4 处冗余死代码（均有实测或属性语义依据）：
  - `setp sys.lmk.kill_timeout_ms 150`（service.sh）：日志显示该属性原本为空，系统从未设默认值，说明无代码消费；真正生效的是 `ro.lmk.kill_timeout_ms`
  - `setprop sys.lmk.reportkills 1`（service.sh）：AOSP lmkd 只认 `ro.lmk.reportkills`，`sys.*` 无消费方
  - `debug.hwui.render_dirty_regions=false`：该属性在 Android 5.0 后已从 HWUI 移除，写入无效
  - `ro.boottime.init.mount_all.early=1`：`ro.boottime.*` 是 init 记录各阶段启动耗时的命名空间（只读统计），不是控制开关，写入无效
- 修正 `ro.control_privapp_permissions=log` 的错误注释：原文写「关掉澎湃激进后台冻结」，实际作用是把 privapp 权限白名单违规从崩溃降级为记日志
- README 整份重写：原内容停留在 v1.1（还写着「本模块不碰 ZRAM」「期望 30720」「swappiness 期望 60」、验证命令查 `ro.lmk.minfree_levels`），全部与现状不符；新版按 v2.3 实际行为写，并补上「Scene 会争抢 lmkd 阈值」「守护可能被系统清理」「thrashing 触发路径与 minfree 无关」三条已知情况

## v2.2 (2026-10-25)
- **代码整理**：抽 `put()` / `setp()` 两个幂等写值函数（只在值变化时才写、才记日志），`apply_all()` 与守护循环去重；守护循环里冗余的 before/after 双读改成由 `put/setp` 自己记录
- service.sh 守护从「短守护（5 分钟退出）」改为**持久化守护**：常驻循环每 60 秒核对一次 swappiness 与 lmkd 阈值，被改回去立刻补回
  - 改的动机：实测证明小米 mem daemon 运行中也会改值（用户刷完用一段时间后 `cat /proc/sys/vm/swappiness` 发现是 120，不是开机那一下），短守护下班后参数会悄悄失效
  - 功耗：`apply_all()` 幂等，值对时只读不写；每分钟唤醒几毫秒，一天累计 CPU 不到 1 秒，噪声级
- 日志裁剪从「退出前裁一次」改为**每 6 小时滚动裁剪**（守护常驻不再退出）
- `post-fs-data.sh` 两段 IO 循环合并成一个 `for dev in sda sdb sdc`（45→39 行），分区注释改成写「分工」而不是版本号
- `system.prop` 删 3 条无效项：`persist.sys.ui.hw`（旧硬件加速开关，已废弃）、`debug.hwui.disable_vsync=false`（默认值，写了等于没写）、`media.stagefright.less-secure` / `ro.audio.monitorOrientation`（与内存卡顿无关）；保留 `persist.sys.fuse.passthrough.enable=true`（注释写的是"保活"但实际是文件直通，改写注释）
- 模块描述补一句「持久化守护系统内存参数，防止被改回旧值」

## v2.1 (2026-10-25)
- service.sh 加「短守护」：开机 45s 后应用参数，随后 5 分钟内每分钟核对一次 swappiness 与 lmkd 阈值，发现被小米 mem daemon 顶回老值就补回去，5 分钟后自动退出（不做死循环常驻，避免白养进程/被省电策略杀/与 daemon 打拉锯）
- 加运行日志 `/data/local/tmp/xaga_lagfix.log`：记录每次参数变更（含被顶回后的修复记录），上限 200 行自动裁剪
- service.sh 重构成 `apply_all()` 幂等函数：只在值不对时才写、才记日志，避免重复写入

## v2.0.1 (2026-10-24)
- 修复真实 bug：删掉 `echo 16 > /proc/sys/vm/min_free_kbytes`（注释写「提到 16MB」实际写 16KB，方向反了，低水位暴跌反而更容易见底硬抖）
- 改过时注释：swappiness 注释从「调低到 60」改为实际的 100
- 清死代码：post-fs-data.sh 62→45 行（删未用的 MODDIR、删永不命中的传统 lowmemorykiller 兜底块、删 ZRAM 空注释段）

## v2.0 (2026-10-24)
- 新增 `page-cluster=0`：swap 少预读，减少 ZRAM 环境换页抖动
- 模块名去掉「·温和版」阶段性叫法，描述重写为 8 项动作全覆盖

## v1.6 (2026-10-24)
- 删掉 `persist.sys.cpu.power_mode=performance`（钉高频白烧电、撞温控掉频），CPU 调度全权交给 Scene「hp 均衡」

## v1.5 (2026-10-24)
- 修复 ZRAM 6GB 未生效：写入时机从 post-fs-data 挪到 service.sh，并补全 swapoff→reset→disksize→mkswap→swapon 五步（之前 disksize 因 busy 写不进）

## v1.4 (2026-10-24)
- ZRAM 改为模块写死 6GB（1:1），不再依赖会崩的 Scene
- swappiness 从 60 调回 100（ZRAM 6GB 后优先走压缩池，而非杀进程）

## v1.3 (2026-10-24)
- 修复 swappiness 被小米 mem daemon 顶回 120：新增 service.sh，开机后期把 swappiness 摁回 60，并压低 sys.mem.swappiness_on_launcher/on_start 源头值

## v1.2
- 撤回误加的动画缩放三件套（不碰动画）
- 加 ro.boottime.init.mount_all.early=1 开机并行加速

## v1.1
- minfree_levels 改成 6GB 合理六档
- 关后台 dex2oat、优化后台/渲染/触控项

## v1.0
- 首版：lmkd + 内存 + IO 调度基础优化

## v1.8 (2026-10-24) — 温和版
- lmkd 阈值整体上移约 25%（38400:0,...,384000:950），提前回收后台，避免内存掉到几十 MB 才见底乱杀（连环 thrashing）
- kill_timeout_ms 100→150，给卡在回收里的进程更多响应时间，减少误杀
- 模块名/描述加「温和版」标识，点明「提前杀、不狠杀、前台更稳」
