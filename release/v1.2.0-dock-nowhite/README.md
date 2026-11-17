# 音栈 v1.2.0 · 浅色底栏「去白」

本目录是「音栈 v1.2.0」（`87 / 1.2.0`）的交付快照：修正浅色模式下底栏玻璃被「纯白 + 提亮」推成近纯白板、在纸面上看起来像一整块背景的问题。

## 实测依据

| 位置 | RGB |
| --- | --- |
| 页面纸色 | (241, 239, 233) |
| 底栏整行背景（圆与条之外） | (241, 238, 231) |
| 迷你播放条本体（改前） | (253, 252, 250) |

底栏根节点没有背景，唯一的 `backgroundColor` 在 `dockGlass()` 且被 `clip(true)` 限制在形状内。真正「像背景」的是播放条本身白过头。

## 改动（仅浅色分支）

| 项 | 改前 | 改后 |
| --- | --- | --- |
| 底色 | `#4DFBFBFB`（纯白 30%） | `#3DFAF9F5`（微暖近白 24%） |
| `brightness` | 1.07 | 1.01 |
| `saturation` | 1.6 | 1.25 |

深色档（`#331A1D24` / `brightness 1.10` / `saturation 1.9`）不变。形状辨识交给顶缘 0.46 高光与 0.55 边框。

## 文件

| 文件 | 说明 |
| --- | --- |
| `音栈-v1.2.0-液态磨砂去白-signed.hap` | **已签名，可直接侧载安装**（3,364,049 字节） |
| `音栈-v1.2.0-液态磨砂去白-unsigned.hap` | 未签名，供 AGC 正式证书或 DevEco 重签（3,312,840 字节） |
| `音栈-v1.2.0-液态磨砂去白-源码工程.zip` | 完整源码工程，195 条目，解压即 `LXMusicHarmony/` |
| `SHA256SUMS.txt` | 三个交付物的校验值 |

已签名 HAP 使用 OpenHarmony 公共调试证书（`compatibleVersion 26`，bundleName `com.yinzhan.music`），适用于侧载；正式分发需用自有 AGC 证书对 unsigned 包重签。签名材料不随仓库分发。

## 验证

- API 26 release `BUILD SUCCESSFUL`（34 tasks）；自检 71 项 PASS 65 / WARN 4 / FAIL 2（2 项为基线自带历史断言，改动前后一致）。
- `sign-app success`；`verify-app` → `Verify success`。
- 落包反查：`3DFAF9F5` 命中，`4DFBFBFB` 归零，`331A1D24` 保留。
- 包身份：`com.yinzhan.music / 87 / 1.2.0`。
