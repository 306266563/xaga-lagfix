# 澎湃OS2 无响应/卡顿优化

Redmi Note 11T Pro（xaga）6GB 专用，HyperOS 2，KernelSU / APatch 挂载式模块。
只写系统属性和 /proc、/sys 参数，不改系统分区，删模块即恢复。

## 做了什么

- 修正 lmkd 阈值。原厂后两档 `55296:900`、`80640:950` 是 6GB 到不了的值，等于没用，改成六档 `38400:0` 到 `384000:950`（单位页，4KB）
- 固定 swappiness 为 100。系统运行中会拉回 120，开机写一次，之后每分钟核对
- zram 从系统默认的 4GB 重建为 6GB，和物理内存 1:1
- 关闭后台 dex2oat，避免重编译抢内存
- 调整 UFS 队列和缓存回写：mq-deadline、nr_requests 256、dirty 回写、vfs_cache_pressure

## 安装

管理器 → 模块 → 本地安装 → 选 zip → 重启。

## 验证

点模块卡片的「执行」，参数不对会当场修正。也可以手动查：

```
getprop sys.lmk.minfree_levels
cat /proc/sys/vm/swappiness
cat /proc/swaps
```

## 卸载

管理器里移除模块，重启。不改系统分区，卸载后完全恢复。

## 注意

- Scene 也会改 lmkd 阈值，两边都开会互相覆盖，建议关掉 Scene 的内存管理
- 守护被系统清理后，点一次「执行」会重新拉起
- thrashing 类 kill 走 `ro.lmk.thrashing_limit`，不受本模块的 minfree 影响
- 录屏和小米互传常被控制中心磁贴反复拉起又被 lmkd 杀，把那两个磁贴移出快捷设置
- 开机慢、App 首次启动慢是 6GB 的常态，模块解决不了

## 文件

`system.prop` `post-fs-data.sh` `service.sh` `guard.sh` `lib.sh` `action.sh` `uninstall.sh`

`service.sh` 必须用 setsid 拉起守护，否则 APatch 在脚本退出时会把子进程一起清掉。

## 许可

GPL-3.0

## 开发

TakuraTears（306266563）& DeepSeek
