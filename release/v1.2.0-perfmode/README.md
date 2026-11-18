# 音栈 v1.2.0 · 流畅优先开关

本目录是「音栈 v1.2.0」（`87 / 1.2.0`）的交付快照：新增「设置 → 外观 → 流畅优先」开关，打开后彻底关掉底栏实时毛玻璃（`backgroundEffect`），只留半透明底色 + 渐变高光 + 边框。默认关闭（保持玻璃观感）。

## 为什么这样做

滚动卡顿不是高刷问题（OpenHarmony 应用默认跟随系统刷新率、无应用侧锁帧 API），而是底栏在所有界面常驻、滚动时每帧重算背景模糊。上一版去掉「双层模糊」后仍有余量，这里把「是否每帧重算模糊」做成开关，交给用户按机型决定，而不是一刀切砍掉观感。

## 改动清单

| 文件 | 改动 |
| --- | --- |
| `common/Constants.ets` | 新增 `PrefKeys.PERF_MODE = 'v4_perf_mode'` |
| `core/Settings.ets` | 新增 `perfMode()` / `setPerfMode()`，写入时广播 `AppStorage('perfMode')` |
| `ui/BottomDock.ets` | 新增 `@StorageProp('perfMode')`；`dockGlass()` 把 `backgroundEffect` 抽成独立透明模糊层，用 `if (!this.perfMode)` 包裹 |
| `ui/pages/AppearanceSettingsPage.ets` | 「主题」分组新增「流畅优先」`SettingSwitchRow`，`reload()` 读回 |

视觉等价性：高斯模糊是线性算子、半透明底色是常数，`blur(α·bg + (1-α)·c) == α·blur(bg) + (1-α)·c`，故把模糊层拆成叠在底色之上的透明 Column 不改变最终像素，只让它可被 `if` 裁剪。

## 文件

| 文件 | 说明 |
| --- | --- |
| `音栈-v1.2.0-流畅优先-源码工程.zip` | 完整源码工程，195 条目，解压即 `LXMusicHarmony/` |
| `SHA256SUMS.txt` | 交付物的校验值 |

## 验证

- API 26 release `BUILD SUCCESSFUL`（34 tasks）；自检 71 项 PASS 65 / WARN 4 / FAIL 2（基线自带历史断言）。
- 落包反查：`perfMode` × 6、`v4_perf_mode` 命中，`backgroundEffect` 仍在（开关分支内）。
- 包身份：`com.yinzhan.music / 87 / 1.2.0`。
