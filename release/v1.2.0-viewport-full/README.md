# 音栈 v1.2.0 · 视口到底（底栏不再裁画面）

本目录是「音栈 v1.2.0」（`87 / 1.2.0`）的交付快照：修掉悬浮底栏上方"内容被硬切、残留一大块纸色"的问题。

## 根因

一级页把"给底栏让位"写在了**外层容器的 padding** 上：

```ts
// 改前 DiscoverPage.ets:915
Column { ... }
  .padding({ left: PAGE_PAD, right: PAGE_PAD, top: this.topSafe + 8, bottom: 150 })
//                                         ↑ 砍的是 Scroll 的可视高度，不是留白
```

Scroll 的可见区域只到「屏幕底 − 150」，再往下全被裁剪。所以底栏玻璃再透，背后也只有纸色。叠加列表末尾的 `Row().height(FLOAT_SPACE)`（154），末尾空白最多 304vp。

## 改动

| 文件 | 改动 |
| --- | --- |
| `DiscoverPage.ets:915` | 外层 Column 去掉 `bottom: 150`（真正的裁剪源） |
| `HomePage.ets:410` | 去掉 `bottom: 150`（在 Scroll 内 Column 上，只减少末尾空白 304 → 154） |
| `SettingsPage.ets:283` | 同上 |

列表内部 `FLOAT_SPACE` 占位保留，末尾仍能滚到底栏之上。

## 文件

| 文件 | 说明 |
| --- | --- |
| `音栈-v1.2.0-视口到底-源码工程.zip` | 完整源码工程，195 条目，解压即 `LXMusicHarmony/` |
| `SHA256SUMS.txt` | 交付物的校验值 |

## 验证

- API 26 release `BUILD SUCCESSFUL`（34 tasks）；自检 71 项 PASS 65 / WARN 4 / FAIL 2（基线自带历史断言）。
- 包身份：`com.yinzhan.music / 87 / 1.2.0`。
