# Ace 5 Pro 官方 OKI 内核 6.6.66

一加 Ace 5 Pro (PKR110) 的**官方 OKI 源码**云编译。

## 为什么用这套源码

| 之前的包 | 本仓库 |
|---|---|
| cctv18 / Goldzxcbug（都是同一套 builder） | OnePlusOSS 官方源码 |
| 源码分支 `..._v_15.0.2_oneplus_13_6.6.66`（一加 13 线） | `..._v_15.0.0_oneplus_ace5_pro`（**本机分支**） |
| `CONFIG_HMBIRD_SCHED=y`（风驰移植） | `CONFIG_SLIM_SCHED=y` + `CONFIG_SCHED_CLASS_EXT=y`（**原厂**） |
| 风驰符号 246 处 | 0 处 |
| 含 `ghost_task` 伪造 task_struct 补丁 | 无 |
| 内置 KernelSU | **不内置**（走修补 init_boot） |

实测两个旧包的 `Image`，`hmbird` 均命中 246 次；`kernel/sched/hmbird/` 在官方源码里是 HTTP 404，
说明风驰是第三方移植进 6.6.66 的，而原厂该机型用的是 `SLIM_SCHED`。

## 编译

Actions 页面手动触发 `Build Ace5Pro OKI Kernel 6.6.66`，约 40 分钟。

产物：
- `AK3_Ace5Pro_OKI_6.6.66.zip` —— 可直接刷（`BLOCK=boot`）
- `Image` —— 裸内核

## 刷入

```bash
adb reboot bootloader
fastboot flash boot AK3_Ace5Pro_OKI_6.6.66.zip   # 或用 KernelFlasher 刷 zip
fastboot reboot
```

> 走 OKI 路线**不需要清 data**。"刷内核要格式化 data" 是 **GKI** 内核的问题
> （cctv18 README 原文："导致欧加真机型刷入 GKI 内核后不清空data分区就无法正常开机"），
> OKI 用的是官方源码、自带绿厂 f2fs 改动，不涉及。

## 回退

刷之前先备份原 boot：

```bash
adb shell su -c "dd if=/dev/block/by-name/boot of=/sdcard/boot_stock.img"
```

出问题就 `fastboot flash boot boot_stock.img`。
