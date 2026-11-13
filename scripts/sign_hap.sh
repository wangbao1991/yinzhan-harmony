#!/usr/bin/env bash
# 使用 OpenHarmony 公共签名材料对 HAP 签名（适用于 OpenHarmony 设备/模拟器）
# HarmonyOS NEXT 华为真机请使用 DevEco Studio 的开发者调试签名重新签名。
set -euo pipefail

: "${OHOS_SDK_LIB:?请设置为 SDK 的 toolchains/lib 目录}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SIGN_DIR="$SCRIPT_DIR/../signing"
IN_FILE="${1:-$SCRIPT_DIR/../entry/build/default/outputs/default/entry-default-unsigned.hap}"
OUT_FILE="${2:-$SCRIPT_DIR/../entry-default-signed.hap}"

java -jar "$OHOS_SDK_LIB/hap-sign-tool.jar" sign-app \
  -mode localSign \
  -keyAlias "openharmony application release" \
  -keyPwd 123456 \
  -appCertFile "$SIGN_DIR/app-chain.pem" \
  -profileFile "$SIGN_DIR/profile.p7b" \
  -inFile "$IN_FILE" \
  -signAlg SHA256withECDSA \
  -keystoreFile "$OHOS_SDK_LIB/OpenHarmony.p12" \
  -keystorePwd 123456 \
  -outFile "$OUT_FILE" \
  -compatibleVersion 12 \
  -signCode 1

java -jar "$OHOS_SDK_LIB/hap-sign-tool.jar" verify-app \
  -inFile "$OUT_FILE" \
  -outCertChain "${OUT_FILE%.hap}-chain.cer" \
  -outProfile "${OUT_FILE%.hap}-profile.p7b"

echo "已签名 HAP: $OUT_FILE"
