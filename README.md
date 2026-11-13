# 音栈 · 鸿蒙原生音乐播放器

用 ArkTS / ArkUI 从零编写的 HarmonyOS / OpenHarmony 原生音乐播放器。Stage 模型、API 26（OpenHarmony 7.0）、零三方依赖、可离线命令行构建。

当前版本：**v1.0**（`versionName 1.0` / `versionCode 67`）

## 这是什么

音栈是一个**播放器框架**：它本身不提供、不内置、不托管任何音乐文件、歌词库或音源脚本。播放能力来自使用者自行导入的兼容自定义音源脚本（洛雪音源 v2 事件协议，并兼容 MusicFree 插件装载契约）。音源脚本运行在 ArkWeb 沙箱中，网络请求由原生侧代理转发。

## 主要能力

- **多音源聚合**：搜索、歌单广场、榜单、发现页动态板块，按音源平台分别组织
- **播放**：播放页、逐行歌词与翻译、播放队列、迷你播放条、通知栏控制
- **下载**：下载管理、真实音质标注；把歌名 / 歌手 / 专辑与歌词**写进音频文件内部**（mp3 用 ID3v2.3 `USLT`、flac 用 Vorbis Comment `LYRICS`），下载目录只产出一个文件，不生成额外 `.lrc`
- **音乐库**：收藏歌单、最近播放、本地音乐、左滑与多选管理
- **账号**：网易云账号登录，歌单收藏与云端账号之间的前台定时对账
- **外观**：纸墨风格、深浅色模式
- **工程**：零三方依赖、命令行离线构建、静态自检护栏（`scripts/selfcheck.py`）

## 编译与重建

工程自带可复现的命令行编译环境，不需要 DevEco Studio 图形界面：

```bash
bash scripts/env/setup_env_26.sh     # 首次搭建 OpenHarmony 7.0 / API 26 环境（约 3 GB）
source scripts/env/env.sh            # 每个新终端载入一次
bash scripts/env/build_release.sh    # 干净构建 → 签名（如有证书）→ 验签 → 版本核对 → 自检
```

- `compatibleSdkVersion` 为 `26.0.0`，API 12 / API 24 工具链无法构建。
- 工程**不含任何签名证书**。缺少 `signing/app-chain.pem` 与 `signing/profile.p7b` 时，流水线会跳过签名并产出 `unsigned HAP`；正式分发请用自己的 AGC / DevEco 证书重新签名。
- `scripts/sign_hap.sh` 里的口令是 OpenHarmony SDK **公共调试密钥的默认公开值**，不是私有凭证。
- 完整避坑说明见 [`docs/编译环境重建指南（避坑版）.md`](docs/编译环境重建指南（避坑版）.md)，音源协议与差异分析见 [`docs/音源协议兼容分析（整合版）.md`](docs/音源协议兼容分析（整合版）.md)。

## 目录结构

```
AppScope/                  应用级配置与资源
entry/src/main/ets/        ArkTS 源码（common / core / ui / entryability）
entry/src/main/resources/  资源、图标、rawfile 音源沙箱
scripts/                   构建、签名、自检、图标工具
docs/                      编译环境重建指南、音源协议分析
hvigor/                    构建配置
```

## 第三方组件

见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。工程内唯一的第三方库是 `crypto-js@4.1.1`（MIT）；`rawfile/vendor/mf_runtime.js` 与 `rawfile/lx_bridge.html` 是本项目自行实现的协议适配层与沙箱页面。

## 免责声明

- 本项目**不内置、不提供、不分发任何音乐文件、歌词或音源脚本**，也不托管任何内容服务；相关能力取决于使用者自行导入的音源脚本。
- 本项目仅供技术学习与个人使用，**不用于绕过任何平台的付费机制、版权保护或访问控制**。使用者须自行遵守各音乐平台的服务条款及所在地区的法律法规。
- 因使用本项目产生的内容、账号或法律问题由使用者自行承担，作者不承担任何责任。
- 权利人如认为本项目涉及其权益，请通过仓库 Issue 联系，我们会及时处理。

## 许可证

本仓库**暂未指定开源许可证**。在 `LICENSE` 落地之前，代码默认适用「保留所有权利」，他人不得复制、修改或再分发。若希望他人合法使用本项目，请补充 `LICENSE`（推荐 MIT 或 Apache-2.0）。
