# 音栈 v1.2.0 · 底栏与播放条加宽

本目录是「音栈 v1.2.0」的交付快照：在 v1.2.0 冻结基线（`versionCode 87` / `versionName 1.2.0`）之上，把底部「迷你播放条 + 页签栏」上下加宽后的构建产物。

## 本轮改动

只改 `entry/src/main/ets/ui/BottomDock.ets` 中的 `DockSize` 三个高度常量：

| 常量 | 含义 | 原值 | 新值 |
| --- | --- | --- | --- |
| `MINI_H` | 迷你播放条高度 | 44 | **52** |
| `TAB_H` | 展开态页签栏高度 | 44 | **52** |
| `CIRCLE` | 收缩后页签圆直径 | 44 | **52** |

三者必须同值：收缩动画按「三条等高」推算，只改其中一两项会让收缩圆变成椭圆、中心错位。

几何自检（`GAP = 6`）：

```
tabY = MINI_H + GAP = 58        收缩态 miniY(t=1) = 58
播放条中心 = 58 + 52/2 = 84      收缩圆心 = 58 + 52/2 = 84    → 中心对齐
dockH = MINI_H + GAP + TAB_H = 110（原 94）；一级页底部留白 150，未遮挡
```

未改动：封面直径 30、图标 18、间距 6/8、侧边留白 26、流光宽度 136、收缩动画、玻璃材质、按压调制、层级顺序，以及播放 / 下载 / 同步全部逻辑。版本号保持 `87 / 1.2.0`（未升版）。

## 文件

| 文件 | 说明 |
| --- | --- |
| `音栈-v1.2.0-底栏加宽-signed.hap` | **已签名，可直接侧载安装**（3,364,513 字节） |
| `音栈-v1.2.0-底栏加宽-unsigned.hap` | 未签名，供 AGC 正式证书或 DevEco Studio 重签（3,312,376 字节） |
| `音栈-v1.2.0-底栏加宽-源码工程.zip` | 完整源码工程，195 条目，解压即 `LXMusicHarmony/` |
| `SHA256SUMS.txt` | 三个交付物的校验值 |

已签名 HAP 使用 OpenHarmony 公共调试证书（`compatibleVersion 26`，bundleName `com.yinzhan.music`），适用于侧载；正式分发需用自有 AGC 证书对 unsigned 包重签。签名材料（`.p12` / `.pem` / `.p7b`）按工程铁律**不入库**。

本目录通过局部 `.gitignore` 显式解除根目录对 `*.hap` / `*.zip` 的忽略，仓库根目录的开源忽略策略保持不变。

## 验证状态

- 静态自检：**71 项，PASS 65 / WARN 4 / FAIL 2**。2 项 FAIL 为 v1.2.0 基线自带的历史断言（`systemMaterialEffect` 沉浸光感、`playerGeomId` 一镜到底），与纸墨风格底栏无关，本轮改动前后计数完全一致。
- 构建：API 26 release `BUILD SUCCESSFUL`（34 tasks）。
- 签名：`sign-app success`；`verify-app` → `Verify success`；profile 绑定 `com.yinzhan.music`。
- 包身份：`com.yinzhan.music / versionCode 87 / versionName 1.2.0`。

## 与仓库的关系

仓库根目录即本版本（`87 / 1.2.0`）的完整源码，本目录只是把「可直接取用的产物」单独放一份，方便不克隆仓库也能下载。

源码工程 zip 与根目录源码一致，可直接对照。签名材料不随仓库分发。
