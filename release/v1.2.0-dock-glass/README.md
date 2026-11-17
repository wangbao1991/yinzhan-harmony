# 音栈 v1.2.0 · 底栏与播放条「液态磨砂玻璃（通透版）」

本目录是「音栈 v1.2.0」的交付快照：在 `87 / 1.2.0` 冻结基线之上，把底部「迷你播放条 + 页签栏」的玻璃材质做成真正通透的液态磨砂。

## 上一版为什么看着还「实」

不是底色不够透，是**两层材质在叠加**：上一版把底色降到 30%，但 `backgroundBlurStyle` 仍是 `COMPONENT_ULTRA_THICK` / `COMPONENT_THICK`——这两个系统档位自带一层不透明底色，和 `backgroundEffect` 一起叠，等于又糊了一层灰。

## 本轮改动

只改 `entry/src/main/ets/ui/BottomDock.ets` 的 `dockGlass()`（页签栏、播放条共用）。

| 项 | 上一版 | 现在 |
| --- | --- | --- |
| 深色底色 | `#4D1A1D24`（30%） | `#331A1D24`（20%） |
| 浅色底色 | `#66FBFBFB`（40%） | `#4DFBFBFB`（30%） |
| 兜底材质 | `ULTRA_THICK` / `THICK` | `COMPONENT_REGULAR` / `COMPONENT_THIN` |
| 模糊半径 | 28 | 30 |
| 亮度 | 1.08 / 1.05 | 1.10 / 1.07 |
| 饱和度 | 1.9 / 1.6 | 不变 |
| 顶缘高光 / 底缘内阴影 | 0.46 / 12% | 不变 |

未改动：底栏高度（52vp 三常量）、几何、收缩动画、流光、按压调制，以及播放 / 下载 / 同步全部逻辑。版本号保持 `87 / 1.2.0`（未升版）。

```ts
.backgroundColor(this.isDark ? '#331A1D24' : '#4DFBFBFB')
.backgroundBlurStyle(this.isDark ? BlurStyle.COMPONENT_REGULAR : BlurStyle.COMPONENT_THIN)
.backgroundEffect({
  radius: 30,
  saturation: this.isDark ? 1.9 : 1.6,
  brightness: this.isDark ? 1.10 : 1.07,
  color: this.isDark ? '#0AFFFFFF' : '#00FFFFFF',
  adaptiveColor: AdaptiveColor.AVERAGE
})
```

## 文件

| 文件 | 说明 |
| --- | --- |
| `音栈-v1.2.0-液态磨砂通透-signed.hap` | **已签名，可直接侧载安装**（3,364,041 字节） |
| `音栈-v1.2.0-液态磨砂通透-unsigned.hap` | 未签名，供 AGC 正式证书或 DevEco Studio 重签（3,312,848 字节） |
| `音栈-v1.2.0-液态磨砂通透-源码工程.zip` | 完整源码工程，195 条目，解压即 `LXMusicHarmony/` |
| `SHA256SUMS.txt` | 三个交付物的校验值 |

已签名 HAP 使用 OpenHarmony 公共调试证书（`compatibleVersion 26`，bundleName `com.yinzhan.music`），适用于侧载；正式分发需用自有 AGC 证书对 unsigned 包重签。签名材料（`.p12` / `.pem` / `.p7b`）按工程铁律**不入库**。

本目录通过局部 `.gitignore` 显式解除根目录对 `*.hap` / `*.zip` 的忽略，仓库根目录的开源忽略策略保持不变。

## 验证状态

- 静态自检：**71 项，PASS 65 / WARN 4 / FAIL 2**。2 项 FAIL 为 v1.2.0 基线自带的历史断言（`systemMaterialEffect`、`playerGeomId`），与本轮改动无关，改动前后计数完全一致。
- 构建：API 26 release `BUILD SUCCESSFUL`（34 tasks）。
- 签名：`sign-app success`；`verify-app` → `Verify success`（SHA-256 digest true）。
- 落包反查：`ets/modules.abc` 命中 `backgroundEffect` / `saturation` / `adaptiveColor` 与 `331A1D24`、`4DFBFBFB`；旧色值归零。
- 包身份：`com.yinzhan.music / versionCode 87 / versionName 1.2.0`。

## 与仓库的关系

仓库根目录即本版本（`87 / 1.2.0`）的完整源码，本目录只是把「可直接取用的产物」单独放一份，方便不克隆仓库也能下载。

源码工程 zip 与根目录源码一致，可直接对照。签名材料不随仓库分发。
