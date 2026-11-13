#!/usr/bin/env bash
# 载入鸿蒙命令行编译环境（必须用 source 执行）：
#   source scripts/env/env.sh
#
# 工具链位置优先级：显式 CLT_DIR > 工程根 .env.local（setup_env_26.sh 写入）> 默认路径自动探测
# 工程要求 API 26 / OpenHarmony 7.0 / hvigor 6.26.4，不要再指向 API 12 的旧工具链。
ENV_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_PROJECT_DIR="$(cd "$ENV_SELF_DIR/../.." && pwd)"
if [ -f "$ENV_PROJECT_DIR/.env.local" ]; then
  # 外部显式传入的 CLT_DIR 优先，不被 .env.local 覆盖；JAVA_HOME 由 .env.local 里的
  # `: "${JAVA_HOME:=...}"` 兜底，已设置时同样保留。
  _ENV_CLT_OVERRIDE="${CLT_DIR:-}"
  # shellcheck disable=SC1091
  . "$ENV_PROJECT_DIR/.env.local"
  if [ -n "$_ENV_CLT_OVERRIDE" ]; then CLT_DIR="$_ENV_CLT_OVERRIDE"; fi
  unset _ENV_CLT_OVERRIDE
fi
if [ -z "${CLT_DIR:-}" ]; then
  for d in /opt/harmonyos/command-line-tools-26 "$HOME/harmonyos/command-line-tools-26" \
           /opt/harmonyos/command-line-tools "$HOME/harmonyos/command-line-tools"; do
    if [ -x "$d/bin/hvigorw" ]; then CLT_DIR="$d"; break; fi
  done
  CLT_DIR="${CLT_DIR:-/opt/harmonyos/command-line-tools-26}"
fi

export CLT_DIR
export COMMANDLINE_TOOL_DIR="$CLT_DIR"
export PATH="$CLT_DIR/bin:$CLT_DIR/tool/node/bin:$PATH"
export DEVECO_SDK_HOME="$CLT_DIR/sdk"
export OHOS_SDK_HOME="$CLT_DIR/sdk"
export OHOS_BASE_SDK_HOME="$CLT_DIR/sdk"
export DEVECO_NODE_HOME="$CLT_DIR/tool/node"
export JAVA_HOME="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")}"
export OHOS_SDK_LIB="$CLT_DIR/sdk/default/openharmony/toolchains/lib"
export NODE_PATH="$CLT_DIR/hvigor/node_modules${NODE_PATH:+:$NODE_PATH}"

[ -x "$CLT_DIR/bin/hvigorw" ] || {
  echo "未找到 hvigorw（CLT_DIR=$CLT_DIR）。请先执行： bash $ENV_SELF_DIR/setup_env_26.sh" >&2
  return 1 2>/dev/null || exit 1
}

# 软校验：工程 compatibleSdkVersion 是 26.0.0，指到 API 12 工具链会构建失败。
_ENV_SDK_PKG="$CLT_DIR/sdk/default/sdk-pkg.json"
if [ -f "$_ENV_SDK_PKG" ]; then
  _ENV_API="$(sed -n 's/.*"apiVersion"[[:space:]]*:[[:space:]]*"\([0-9]*\)".*/\1/p' "$_ENV_SDK_PKG" | head -1)"
  if [ -n "$_ENV_API" ] && [ "$_ENV_API" != "26" ]; then
    echo "警告：当前工具链 API $_ENV_API，工程要求 API 26（build-profile.json5 compatibleSdkVersion 26.0.0）。" >&2
    echo "      如需重建： bash $ENV_SELF_DIR/setup_env_26.sh" >&2
  fi
  unset _ENV_API
fi
unset _ENV_SDK_PKG
