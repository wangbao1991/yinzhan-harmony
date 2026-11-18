# 音栈 v1.2.0 · 流畅性优化（底栏去双层模糊）

本目录是「音栈 v1.2.0」（`87 / 1.2.0`）的交付快照：降低悬浮底栏滚动时的实时模糊开销，缓解多界面滚动卡顿。

## 结论

不是高刷问题——OpenHarmony 应用默认跟随系统刷新率，`@ohos.window` 无应用侧锁帧 API。卡顿来自底栏滚动时**每帧重排 + 两层实时模糊**（`backgroundBlurStyle` + `backgroundEffect`）。

## 改动（`BottomDock.ets` 的 `dockGlass()`）

| 项 | 改前 | 改后 |
| --- | --- | --- |
| `backgroundBlurStyle` | 保留 | 删除，只留 `backgroundEffect` |
| `radius` | 30 | 22 |
| `saturation` | 1.9 / 1.25 | 1.55 / 1.15 |
| `brightness` | 1.10 / 1.01 | 1.06 / 1.01 |

## 文件

| 文件 | 说明 |
| --- | --- |
| `音栈-v1.2.0-流畅优化-源码工程.zip` | 完整源码工程，195 条目，解压即 `LXMusicHarmony/` |
| `SHA256SUMS.txt` | 交付物的校验值 |

## 验证

- API 26 release `BUILD SUCCESSFUL`（34 tasks）；自检 71 项 PASS 65 / WARN 4 / FAIL 2（基线自带历史断言）。
- 落包反查：`backgroundEffect` 命中，`COMPONENT_*` 模糊档位归零。
- 包身份：`com.yinzhan.music / 87 / 1.2.0`。
