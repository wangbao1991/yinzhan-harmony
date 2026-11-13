#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 音栈 / HarmonyOS 7.0（OpenHarmony 7.0-Release / API 26）命令行编译环境一键搭建
# 免华为账号登录：全部来自三个可匿名访问的公开源，不用 DevEco Studio 图形界面。
#
# 用法（在任意目录执行均可）：
#   bash scripts/env/setup_env_26.sh                     # 默认装到 /opt/harmonyos/command-line-tools-26
#   CLT_DIR=$HOME/harmonyos/command-line-tools-26 \
#     bash scripts/env/setup_env_26.sh                   # 无 root 权限时自定义位置
#   FORCE=1 bash scripts/env/setup_env_26.sh             # 已装过也强制重来
#   CACHE_DIR=/my/cache bash scripts/env/setup_env_26.sh # 自定义下载缓存
#
# 成功后把 CLT_DIR / JAVA_HOME 写进工程根 .env.local，之后 source env.sh 自动读取。
# 详见 docs/编译环境重建指南（避坑版）.md
# ---------------------------------------------------------------------------
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SELF_DIR/../.." && pwd)"

SDK_URL="https://repo.huaweicloud.com/openharmony/os/7.0-Release/ohos-sdk-windows_linux-public.tar.gz"
NPM_BASE="https://repo.harmonyos.com/npm"
HVIGOR_VER="6.26.4"
SDK_VER="26.0.0.38"
API_VER="26"
PLATFORM_VER="26.0.0"

CLT_DIR="${CLT_DIR:-/opt/harmonyos/command-line-tools-26}"
CACHE_DIR="${CACHE_DIR:-/tmp/hmos26-cache}"
FORCE="${FORCE:-0}"

SDK_PKG_TGZ="$CACHE_DIR/ohos-sdk-7.0-public.tar.gz"
HVIGOR_TGZ="$CACHE_DIR/hvigor-${HVIGOR_VER}.tgz"
PLUGIN_TGZ="$CACHE_DIR/hvigor-ohos-plugin-${HVIGOR_VER}.tgz"

SDK_ROOT="$CLT_DIR/sdk"
SDK_DEFAULT="$SDK_ROOT/default"
SDK_OH="$SDK_DEFAULT/openharmony"
SDK_HMS="$SDK_DEFAULT/hms"

log() { printf '\n\033[1;36m[%s]\033[0m %s\n' "$1" "$2"; }
die() { printf '\033[1;31m错误:\033[0m %s\n' "$1" >&2; exit 1; }

log "0/9" "前置检查"
for c in curl unzip tar java node python3; do
  command -v "$c" >/dev/null 2>&1 || die "缺少系统命令: $c"
done
printf '  node  : %s\n' "$(node -v)"
printf '  java  : %s\n' "$(java -version 2>&1 | head -1)"
printf '  CLT   : %s\n' "$CLT_DIR"

# JDK 21 是 API 26 工具链的推荐版本；17 及以上实测也可构建，低于 17 明确拒绝。
JDK_HOME=""
for cand in "${JAVA_HOME:-}" /usr/lib/jvm/java-21-openjdk-amd64 /usr/lib/jvm/java-21-openjdk /usr/lib/jvm/java-17-openjdk-amd64; do
  if [ -n "$cand" ] && [ -x "$cand/bin/java" ]; then
    major="$("$cand/bin/java" -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -1)"
    if [ -n "$major" ] && [ "$major" -ge 17 ]; then JDK_HOME="$cand"; break; fi
  fi
done
if [ -z "$JDK_HOME" ]; then
  major="$(java -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -1)"
  [ -n "$major" ] && [ "$major" -ge 17 ] || die "需要 JDK 17 及以上（推荐 21），当前：$(java -version 2>&1 | head -1)"
  JDK_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
fi
printf '  JDK   : %s\n' "$JDK_HOME"

if [[ -f "$SDK_DEFAULT/sdk-pkg.json" && -x "$CLT_DIR/bin/hvigorw" && "$FORCE" != "1" ]]; then
  log "完成" "API 26 工具链已存在，跳过重建（FORCE=1 可强制重来）"
  printf 'CLT_DIR=%s\n: "${JAVA_HOME:=%s}"\n' "$CLT_DIR" "$JDK_HOME" > "$PROJECT_DIR/.env.local"
  exit 0
fi

mkdir -p "$CACHE_DIR" "$CLT_DIR/bin" "$CLT_DIR/tool/node/bin" "$CLT_DIR/hvigor/node_modules/@ohos"

log "1/9" "获取三个公开源（缓存命中即跳过下载）"
fetch() {
  local url="$1" dst="$2"
  if [[ -s "$dst" ]]; then
    printf '  缓存命中: %s (%s)\n' "$(basename "$dst")" "$(du -h "$dst" | cut -f1)"
    return 0
  fi
  printf '  下载: %s\n' "$url"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "${dst}.part" "$url"
  mv "${dst}.part" "$dst"
  printf '  完成: %s\n' "$(du -h "$dst" | cut -f1)"
}
fetch "$SDK_URL" "$SDK_PKG_TGZ"
fetch "$NPM_BASE/@ohos/hvigor/-/hvigor-${HVIGOR_VER}.tgz" "$HVIGOR_TGZ"
fetch "$NPM_BASE/@ohos/hvigor-ohos-plugin/-/hvigor-ohos-plugin-${HVIGOR_VER}.tgz" "$PLUGIN_TGZ"

log "2/9" "解包 hvigor 与插件（坑3：tarball 自带 vendor 依赖，禁止 npm install）"
rm -rf "$CLT_DIR/hvigor/hvigor" "$CLT_DIR/hvigor/hvigor-ohos-plugin"
mkdir -p "$CLT_DIR/hvigor/hvigor" "$CLT_DIR/hvigor/hvigor-ohos-plugin"
tar xzf "$HVIGOR_TGZ" -C "$CLT_DIR/hvigor/hvigor" --strip-components=1
tar xzf "$PLUGIN_TGZ" -C "$CLT_DIR/hvigor/hvigor-ohos-plugin" --strip-components=1
ln -sfn ../../hvigor "$CLT_DIR/hvigor/node_modules/@ohos/hvigor"
ln -sfn ../../hvigor-ohos-plugin "$CLT_DIR/hvigor/node_modules/@ohos/hvigor-ohos-plugin"
[[ -d "$CLT_DIR/hvigor/hvigor/node_modules/@baize/wdk" ]] || printf '  提示: @baize/wdk 目录形态与 5.x 不同，以构建实测为准\n'
printf '  两个 @ohos 作用域软链已建立\n'

log "3/9" "展开 OpenHarmony 7.0 公开 SDK 的五个 linux 组件"
EXTRACT="$CACHE_DIR/sdk26-extract"
rm -rf "$EXTRACT" && mkdir -p "$EXTRACT"
# 7.0 的 tar 顶层是 ohos-sdk/linux/（5.0.0 是裸 linux/），只解 linux 省一半
tar xzf "$SDK_PKG_TGZ" -C "$EXTRACT" ohos-sdk/linux/
mapfile -t ZIPS < <(find "$EXTRACT" -type f -iname "*linux-x64-*.zip" | sort)
printf '  找到 %s 个组件 zip\n' "${#ZIPS[@]}"
[[ ${#ZIPS[@]} -ge 5 ]] || die "SDK 组件 zip 少于 5 个，包结构可能已变化"

mkdir -p "$SDK_OH"
for z in "${ZIPS[@]}"; do
  comp=""
  for c in ets js native previewer toolchains; do
    if [[ "$(basename "$z")" == *"$c-linux-x64"* ]]; then comp="$c"; break; fi
  done
  [[ -n "$comp" ]] || { printf '  跳过无法识别的: %s\n' "$(basename "$z")"; continue; }
  tmp="$CACHE_DIR/unzip26-$comp"
  rm -rf "$tmp"; mkdir -p "$tmp"
  unzip -q -o "$z" -d "$tmp"
  pkgjson="$(find "$tmp" -name 'oh-uni-package.json' -print -quit 2>/dev/null || true)"
  if [[ -n "$pkgjson" ]]; then
    src="$(dirname "$pkgjson")"
  else
    src="$tmp"
    shopt -s nullglob; top=("$tmp"/*); shopt -u nullglob
    if [[ ${#top[@]} -eq 1 && -d "${top[0]}" ]]; then src="${top[0]}"; fi
  fi
  mkdir -p "$SDK_OH/$comp"
  cp -a "$src/." "$SDK_OH/$comp/"
  printf '  %-12s <- %s\n' "$comp" "$(basename "$z")"
  rm -rf "$tmp"
done
for c in ets js native previewer toolchains; do
  [[ -d "$SDK_OH/$c" ]] || die "SDK 组件缺失: $c"
done
# 决定性校验：apiVersion 必须为 26
python3 -c "
import json
d=json.load(open('$SDK_OH/ets/oh-uni-package.json'))
print('  ets apiVersion =', d['apiVersion'], '/ platformVersion =', d.get('platformVersion'))
assert d['apiVersion']=='26', 'apiVersion 不是 26，工程 compatibleSdkVersion=26.0.0 会构建失败'
"
printf '  SDK 版本校验通过: API 26 / %s\n' "$SDK_VER"

log "4/9" "写 sdk-pkg.json（坑1：单组件格式 data.path=default）"
mkdir -p "$SDK_DEFAULT"
cat > "$SDK_DEFAULT/sdk-pkg.json" <<JSON
{
  "meta": { "version": "3.0.0" },
  "data": {
    "apiVersion": "${API_VER}",
    "displayName": "HarmonyOS 7.0.0 (OpenHarmony 7.0-Release)",
    "path": "default",
    "version": "${SDK_VER}",
    "releaseType": "Beta",
    "platformVersion": "${PLATFORM_VER}",
    "stage": "Beta"
  }
}
JSON
python3 -c "
import json
d=json.load(open('$SDK_DEFAULT/sdk-pkg.json'))
assert isinstance(d['data'],dict) and d['data']['path']=='default'
print('  单组件格式校验通过: API', d['data']['apiVersion'], '/', d['data']['version'])
"

log "5/9" "建 hms 空占位（坑2：真实空目录 + uni-package.json，绝不软链）"
mkdir -p "$SDK_HMS"
for c in ets js native previewer toolchains; do
  mkdir -p "$SDK_HMS/$c"
  if [[ -f "$SDK_OH/$c/oh-uni-package.json" ]]; then
    cp "$SDK_OH/$c/oh-uni-package.json" "$SDK_HMS/$c/uni-package.json"
  else
    printf '{\n  "apiVersion": "%s",\n  "version": "%s"\n}\n' "$API_VER" "$SDK_VER" > "$SDK_HMS/$c/uni-package.json"
  fi
done
[[ ! -L "$SDK_HMS" ]] || die "hms 不能是软链接"
printf '  五个占位目录均为真实目录（避免 restool same ID）\n'

log "6/9" "补 hms/toolchains 校验 schema（坑4：PreBuild 会读 modulecheck/app.json）"
for d in modulecheck configcheck syscapcheck; do
  if [[ -d "$SDK_OH/toolchains/$d" ]]; then
    rm -rf "$SDK_HMS/toolchains/$d"
    cp -a "$SDK_OH/toolchains/$d" "$SDK_HMS/toolchains/$d"
    printf '  已复制 %s\n' "$d"
  else
    alt="$(find "$SDK_OH" -type d -name "$d" -print -quit 2>/dev/null || true)"
    if [[ -n "$alt" ]]; then cp -a "$alt" "$SDK_HMS/toolchains/$d"; printf '  已从 %s 复制 %s\n' "$alt" "$d";
    else mkdir -p "$SDK_HMS/toolchains/$d"; printf '  警告: %s 在 SDK 中不存在，建空目录\n' "$d" >&2; fi
  fi
done
[[ -f "$SDK_HMS/toolchains/modulecheck/app.json" ]] || die "modulecheck/app.json 仍缺失"

log "7/9" "补 hms/toolchains/lib 占位库（坑5：公开 SDK 缺闭源 HMS 图片转码库）"
# API 26 / hvigor 6.26.4 的 CompileResource 会无条件把
# optCompression.context.extensionPath 传给 restool，restool 会 dlopen
# hms/toolchains/lib/libimage_transcoder_shared.so —— 即使工程没启用图片压缩。
# 该库属闭源 HMS 组件，OpenHarmony 公开 SDK 里不存在，缺失会 Error 11201001。
# 工程未配置 resOptions.compression，restool 只 dlopen、不调用转码符号，
# 故放一个零依赖的标准共享库作占位即可（不冒充任何鸿蒙组件）。
mkdir -p "$SDK_HMS/toolchains/lib"
STUB_LIB="$SDK_HMS/toolchains/lib/libimage_transcoder_shared.so"
if [[ ! -e "$STUB_LIB" ]]; then
  ZLIB_SRC=""
  for cand in /lib/x86_64-linux-gnu/libz.so.1 /usr/lib/x86_64-linux-gnu/libz.so.1 /lib/aarch64-linux-gnu/libz.so.1 /usr/lib/libz.so.1; do
    [[ -f "$cand" ]] && { ZLIB_SRC="$cand"; break; }
  done
  if [[ -z "$ZLIB_SRC" ]] && command -v ldconfig >/dev/null 2>&1; then
    ZLIB_SRC="$(ldconfig -p 2>/dev/null | awk '/libz\.so\.1 /{print $NF; exit}')"
  fi
  [[ -n "$ZLIB_SRC" && -f "$ZLIB_SRC" ]] || die "找不到 libz.so.1 用于占位；请手工放置一个零依赖 .so 到 $STUB_LIB"
  cp "$ZLIB_SRC" "$STUB_LIB"
  printf '  坑5 占位: %s <- %s\n' "$(basename "$STUB_LIB")" "$ZLIB_SRC"
fi

log "8/9" "软链系统 Node 并生成 bin/hvigorw wrapper"
for b in node npm npx; do
  target="$(command -v "$b" || true)"
  [[ -n "$target" ]] && ln -sfn "$target" "$CLT_DIR/tool/node/bin/$b"
done
cat > "$CLT_DIR/bin/hvigorw" <<'WRAPPER'
#!/usr/bin/env bash
# API 26 并行工具链的 hvigorw：显式设置 NODE_PATH / SDK / NODE_HOME
set -euo pipefail
CLT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVECO_NODE_HOME="$CLT_DIR/tool/node"
export NODE_HOME="$DEVECO_NODE_HOME"
export DEVECO_SDK_HOME="$CLT_DIR/sdk"
export OHOS_SDK_HOME="$CLT_DIR/sdk"
export OHOS_BASE_SDK_HOME="$CLT_DIR/sdk"
export OHOS_SDK_LIB="$CLT_DIR/sdk/default/openharmony/toolchains/lib"
export NODE_PATH="$CLT_DIR/hvigor/node_modules${NODE_PATH:+:$NODE_PATH}"
export PATH="$CLT_DIR/tool/node/bin:$PATH"
exec "$CLT_DIR/tool/node/bin/node" "$CLT_DIR/hvigor/hvigor/bin/hvigor.js" "$@"
WRAPPER
chmod +x "$CLT_DIR/bin/hvigorw"

log "9/9" "验证并写入 .env.local"
export NODE_PATH="$CLT_DIR/hvigor/node_modules"
HV_OUT="$("$CLT_DIR/bin/hvigorw" -v 2>&1 | tail -1)"
printf '  hvigorw -v : %s\n' "$HV_OUT"
[[ "$HV_OUT" == *"$HVIGOR_VER"* ]] || die "hvigorw 版本不是 ${HVIGOR_VER}"
[[ -f "$SDK_OH/toolchains/lib/hap-sign-tool.jar" ]] || die "缺少 hap-sign-tool.jar"
[[ -f "$SDK_OH/toolchains/lib/OpenHarmony.p12" ]] || die "缺少 OpenHarmony.p12"

cat > "$PROJECT_DIR/.env.local" <<ENV
# 本机产物，不要提交版本库 / 不要打进源码包
# 由 scripts/env/setup_env_26.sh 生成：API 26（OpenHarmony 7.0 / hvigor ${HVIGOR_VER} / JDK 17+）
CLT_DIR=$CLT_DIR
: "\${JAVA_HOME:=$JDK_HOME}"
ENV

printf '\n\033[1;32mAPI 26 工具链就绪:\033[0m %s\n' "$CLT_DIR"
printf '接下来：\n  source scripts/env/env.sh\n  bash   scripts/env/build_release.sh\n'
