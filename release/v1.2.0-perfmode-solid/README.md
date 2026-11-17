# 音栈 v1.2.0 · 流畅优先「加实」

本目录是「音栈 v1.2.0」（`87 / 1.2.0`）的交付快照：打开「流畅优先」（关掉底栏实时模糊）后，底栏不再透成塑料膜，改为用更实的底色撑住形状。**玻璃档（开关关闭）完全未改动。**

## 为什么

玻璃档的 20%/24% 底色本来就是配合模糊用的：模糊把背后内容糊成色块，20% 底色只负责压一点点，观感才「透而不空」。perfMode 关掉 `backgroundEffect` 后，同样的 20% 会直接露出背后的原始细节，看起来就是一层透明膜。

## 两档底色

| 档位 | 深色 | 浅色 | 模糊 |
| --- | --- | --- | --- |
| 玻璃档（默认，开关关） | `#331A1D24`（20%） | `#3DFAF9F5`（24%） | radius 22 |
| 流畅优先档（开关开） | `#B31A1D24`（70%） | `#D9F6F4EE`（85%，微暖近白） | 无 |

浅色不用纯白：`#F6F4EE` 比页面纸色 `#F1EFE9` 只亮 5 个点，实但不刺眼。

## 改动

只有一处：`ui/BottomDock.ets` 的 `dockGlass()` 里 `backgroundColor` 按 `perfMode` 分档取值。

```ts
.backgroundColor(this.isDark
  ? (this.perfMode ? '#B31A1D24' : '#331A1D24')
  : (this.perfMode ? '#D9F6F4EE' : '#3DFAF9F5'))
```

## 文件

| 文件 | 说明 |
| --- | --- |
| `音栈-v1.2.0-流畅优先加实-signed.hap` | **已签名，可直接侧载安装**（3,369,250 字节） |
| `音栈-v1.2.0-流畅优先加实-unsigned.hap` | 未签名，供 AGC 正式证书或 DevEco 重签（3,315,832 字节） |
| `音栈-v1.2.0-流畅优先加实-源码工程.zip` | 完整源码工程，195 条目，解压即 `LXMusicHarmony/` |
| `SHA256SUMS.txt` | 三个交付物的校验值 |

已签名 HAP 使用 OpenHarmony 公共调试证书（`compatibleVersion 26`，bundleName `com.yinzhan.music`），适用于侧载；正式分发需用自有 AGC 证书对 unsigned 包重签。签名材料不随仓库分发。

## 验证

- API 26 release `BUILD SUCCESSFUL`（34 tasks）；自检 71 项 PASS 65 / WARN 4 / FAIL 2（基线自带历史断言）。
- `sign-app success`；`verify-app` → `Verify success`。
- 落包反查：四个底色全部命中，`perfMode` × 6。
- 包身份：`com.yinzhan.music / 87 / 1.2.0`。
