#!/usr/bin/env bash
# =============================================================================
# 音栈 / HarmonyOS 5.0.0 (API 12) 命令行编译环境一键搭建
# 免华为账号登录：从华为云公开 SDK + 华为公开 npm 仓库拼装等价的 command-line-tools
#
# 用法（在任意目录执行均可）：
#   bash scripts/env/setup_env.sh                       # 默认装到 /opt/harmonyos/command-line-tools
#   CLT_DIR=$HOME/harmonyos/command-line-tools \
#     bash scripts/env/setup_env.sh                    # 无 root 权限时自定义位置
#   CACHE_DIR=/my/cache bash scripts/env/setup_env.sh  # 自定义下载缓存
#
# 成功后把位置写入工程根的 .env.local，之后 source env.sh 会自动读取。
# 详见 docs/编译环境重建指南（避坑版）.md
# =============================================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SELF_DIR/../.." && pwd)"

CLT_DIR="${CLT_DIR:-/opt/harmonyos/command-line-tools}"
CACHE_DIR="${CACHE_DIR:-/tmp/hmos-setup-cache}"
HVIGOR_VER="5.8.9"          # 对应 DevEco / Command Line Tools 5.0.3.906
SDK_VER="5.0.0.71"          # HarmonyOS 5.0.0 / API 12

SDK_URL="https://repo.huaweicloud.com/openharmony/os/5.0.0-Release/ohos-sdk-windows_linux-public.tar.gz"
NPM="https://repo.harmonyos.com/npm"
HVIGOR_TGZ="$NPM/@ohos/hvigor/-/@ohos/hvigor-${HVIGOR_VER}.tgz"
PLUGIN_TGZ="$NPM/@ohos/hvigor-ohos-plugin/-/@ohos/hvigor-ohos-plugin-${HVIGOR_VER}.tgz"

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------- 0. 前置检查 ----------
log "检查系统依赖"
for c in curl unzip tar node npm java python3; do
  command -v "$c" >/dev/null 2>&1 || die "缺少命令：$c"
done
NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]')
[ "$NODE_MAJOR" -ge 14 ] || die "Node 版本过低（当前 $(node -v)），需 >= 14.19"
echo "OS: $(uname -srm) | Node: $(node -v) | Java: $(java -version 2>&1 | head -1)"
echo "目标目录: $CLT_DIR"

mkdir -p "$CLT_DIR" "$CACHE_DIR" || die "无法创建目录，若为权限问题请用 CLT_DIR 指到可写路径"

# ---------- 1. 下载 ----------
log "下载 OpenHarmony 5.0.0 公开 SDK（约 2.6 GB，内含 API 12 组件）"
SDK_TGZ="$CACHE_DIR/ohos-sdk-public.tar.gz"
if [ ! -s "$SDK_TGZ" ]; then
  curl -fL --retry 3 --max-time 3600 "$SDK_URL" -o "$SDK_TGZ"
fi
[ "$(stat -c %s "$SDK_TGZ")" -gt 2000000000 ] || die "SDK 包不完整：$(stat -c %s "$SDK_TGZ") 字节"

log "下载 hvigor 与 hvigor-ohos-plugin ${HVIGOR_VER}（自带全部依赖，无需 npm/ohpm install）"
for u in "$HVIGOR_TGZ" "$PLUGIN_TGZ"; do
  f="$CACHE_DIR/$(basename "$u")"
  [ -s "$f" ] || curl -fL --retry 3 --max-time 600 "$u" -o "$f"
  tar tzf "$f" >/dev/null || die "tarball 损坏：$f"
done

# ---------- 2. 组装 SDK ----------
log "解压 SDK 组件到 \$CLT_DIR/sdk/default/openharmony"
SDK_ROOT="$CLT_DIR/sdk/default"
mkdir -p "$SDK_ROOT/openharmony" "$CACHE_DIR/sdk-extract"
if [ ! -f "$SDK_ROOT/openharmony/toolchains/oh-uni-package.json" ]; then
  tar xzf "$SDK_TGZ" -C "$CACHE_DIR/sdk-extract" linux/
  for z in "$CACHE_DIR/sdk-extract/linux/"*.zip; do
    echo "  解压 $(basename "$z")"
    unzip -o -q "$z" -d "$SDK_ROOT/openharmony/"
  done
fi

# 避坑点 1：sdk-pkg.json 必须是「单组件」格式（meta + data 对象）。
# 写成组件数组会导致 HosLocalComponentLoader 解析不出组件 → SDK component missing
log "生成 sdk-pkg.json 与 hms 占位元数据"
cat > "$SDK_ROOT/sdk-pkg.json" <<EOF
{
  "meta": { "version": "3.0.0" },
  "data": {
    "apiVersion": "12",
    "displayName": "HarmonyOS 5.0.0",
    "path": "default",
    "version": "${SDK_VER}",
    "releaseType": "Release",
    "platformVersion": "5.0.0",
    "stage": "Release"
  }
}
EOF

# 避坑点 2：HMS 组件只是给 hvigor 做存在性校验（需 uni-package.json）。
# 必须是「空占位目录」，绝不能软链到 openharmony —— 否则 restool 会重复加载
# 系统资源并报 "'ohos_id_color_foreground' and ... defined the same ID"。
mkdir -p "$SDK_ROOT/hms"
for n in ets js native previewer toolchains; do
  mkdir -p "$SDK_ROOT/hms/$n"
  cp "$SDK_ROOT/openharmony/$n/oh-uni-package.json" "$SDK_ROOT/hms/$n/uni-package.json"
done

# 避坑点 4：HMS 侧的 toolchains 还要承担 app.json5 / module.json5 的 schema 校验
# （getAppSchema / getModuleSchema 指向 hms/toolchains/modulecheck/*.json）。
# 只改 .ets 时校验可能被缓存跳过，一旦改了 module.json5 等配置就会触发，
# 缺文件会直接 "Failed :entry:default@PreBuild ... modulecheck/app.json ENOENT"。
# 只补三个纯 JSON 校验目录；绝不能把整个 hms 软链到 openharmony（见避坑点 2）。
log "补齐 HMS toolchains 的配置校验 schema"
for d in modulecheck configcheck syscapcheck; do
  rm -rf "$SDK_ROOT/hms/toolchains/$d"
  cp -a "$SDK_ROOT/openharmony/toolchains/$d" "$SDK_ROOT/hms/toolchains/$d"
done

# ---------- 3. 组装 hvigor ----------
# 避坑点 3：tarball 已 vendor 全部依赖（含未公开的 @baize/wdk），
# 不要改用 npm install 从公共 registry 安装，否则 @baize/wdk 404。
log "解压 hvigor 工具（版本 ${HVIGOR_VER}）"
H="$CLT_DIR/hvigor"
mkdir -p "$H/hvigor" "$H/hvigor-ohos-plugin" "$H/node_modules/@ohos"
tar xzf "$CACHE_DIR/hvigor-${HVIGOR_VER}.tgz" -C "$H/hvigor" --strip-components=1
tar xzf "$CACHE_DIR/hvigor-ohos-plugin-${HVIGOR_VER}.tgz" -C "$H/hvigor-ohos-plugin" --strip-components=1
ln -sfn "$H/hvigor" "$H/node_modules/@ohos/hvigor"
ln -sfn "$H/hvigor-ohos-plugin" "$H/node_modules/@ohos/hvigor-ohos-plugin"

# 内置 Node（DEVECO_NODE_HOME 需含 bin/node）
mkdir -p "$CLT_DIR/tool/node/bin"
ln -sfn "$(command -v node)" "$CLT_DIR/tool/node/bin/node"
ln -sfn "$(command -v npm)" "$CLT_DIR/tool/node/bin/npm"
ln -sfn "$(command -v npx)" "$CLT_DIR/tool/node/bin/npx"

# ---------- 4. 生成 hvigorw ----------
log "生成 bin/hvigorw"
mkdir -p "$CLT_DIR/bin"
cat > "$CLT_DIR/bin/hvigorw" <<'EOF'
#!/usr/bin/env bash
# HarmonyOS Command Line Tools - hvigor wrapper (reconstructed)
CLT_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
HVIGOR_HOME="$CLT_DIR/hvigor"
export NODE_PATH="$HVIGOR_HOME/node_modules${NODE_PATH:+:$NODE_PATH}"
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$CLT_DIR/sdk}"
export DEVECO_NODE_HOME="${DEVECO_NODE_HOME:-$CLT_DIR/tool/node}"
exec "$DEVECO_NODE_HOME/bin/node" "$HVIGOR_HOME/hvigor/bin/hvigor.js" "$@"
EOF
chmod +x "$CLT_DIR/bin/hvigorw"

# ---------- 5. 验证 ----------
log "验证安装"
"$CLT_DIR/bin/hvigorw" -v | grep -q "$HVIGOR_VER" || die "hvigorw 版本不是 ${HVIGOR_VER}"
[ -f "$SDK_ROOT/openharmony/toolchains/lib/hap-sign-tool.jar" ] || die "缺少 hap-sign-tool.jar"
[ -f "$SDK_ROOT/openharmony/toolchains/lib/OpenHarmony.p12" ] || die "缺少 OpenHarmony.p12"
[ -f "$SDK_ROOT/hms/toolchains/modulecheck/app.json" ] || die "缺少 HMS 配置校验 schema（modulecheck/app.json）"
echo "hvigorw        : $("$CLT_DIR/bin/hvigorw" -v)"
echo "sdk-pkg.json   : $(python3 -c "import json;d=json.load(open('$SDK_ROOT/sdk-pkg.json'))['data'];print(d['displayName'], d['version'], 'API', d['apiVersion'])")"
echo "SDK 组件       : $(ls "$SDK_ROOT/openharmony" | tr '\n' ' ')"

# 记住位置，供 env.sh 自动读取
printf 'CLT_DIR=%s\n' "$CLT_DIR" > "$PROJECT_DIR/.env.local"
echo
echo "安装完成。接下来执行："
echo "  source $SELF_DIR/env.sh"
echo "  bash   $SELF_DIR/build_release.sh"
