#!/usr/bin/env bash
# 命令行构建（HarmonyOS Command Line Tools）
set -euo pipefail

: "${COMMANDLINE_TOOL_DIR:?请设置为 command-line-tools 目录，例如 /opt/command-line-tools}"

export PATH="$COMMANDLINE_TOOL_DIR/bin:$COMMANDLINE_TOOL_DIR/tool/node/bin:$PATH"
export DEVECO_SDK_HOME="$COMMANDLINE_TOOL_DIR/sdk"
export DEVECO_NODE_HOME="$COMMANDLINE_TOOL_DIR/tool/node"
export JAVA_HOME="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")}"

cd "$(dirname "$0")/.."
hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
echo "未签名 HAP: entry/build/default/outputs/default/entry-default-unsigned.hap"
