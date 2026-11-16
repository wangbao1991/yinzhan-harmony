#!/usr/bin/env bash
# =============================================================================
# 音栈完整交付流水线：版本自查 → 干净构建 → 产物核对 → 签名核验 → 静态自检
# 版本号唯一事实来源是 AppScope/app.json5，本脚本不再硬编码版本。
# 用法：
#   bash scripts/env/build_release.sh                       # 工程根、输出到 build/
#   bash scripts/env/build_release.sh /path/to/project /tmp/out.hap
# 依赖：先执行 setup_env_26.sh 搭建 API 26 工具链（或已安装官方 Command Line Tools）
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/env.sh"

PROJECT_DIR="${1:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
cd "$PROJECT_DIR"

APP_JSON="$PROJECT_DIR/AppScope/app.json5"
[ -f "$APP_JSON" ] || { echo "未找到 $APP_JSON"; exit 1; }

echo "==> [0/5] 版本自查（读 AppScope/app.json5）"
read -r EXPECT_CODE EXPECT_NAME <<< "$(python3 - "$APP_JSON" <<'PY'
import re, sys
s = open(sys.argv[1], encoding='utf-8').read()
code = re.search(r'"versionCode"\s*:\s*(\d+)', s).group(1)
name = re.search(r'"versionName"\s*:\s*"([^"]+)"', s).group(1)
print(code, name)
PY
)"
export EXPECT_CODE EXPECT_NAME
echo "versionCode = $EXPECT_CODE | versionName = $EXPECT_NAME"

OUT_HAP="${2:-$PROJECT_DIR/build/音栈-v${EXPECT_NAME}-signed.hap}"
mkdir -p "$(dirname "$OUT_HAP")"

echo "==> [1/5] 干净构建（release）"
rm -rf entry/build
hvigorw assembleHap --mode module -p product=default -p buildMode=release --no-daemon | tee /tmp/yinzhan-build.log
grep -q "BUILD SUCCESSFUL" /tmp/yinzhan-build.log || { echo "构建失败"; exit 1; }
UNSIGNED="entry/build/default/outputs/default/entry-default-unsigned.hap"
[ -s "$UNSIGNED" ] || { echo "未找到 unsigned HAP"; exit 1; }

echo "==> [2/5] 输出 unsigned HAP（签名交由云端 / DevEco 完成）"
# 源码工程包**不带任何签名材料**（云构建平台会把 .cer / .p12 / .p7b / .pem 判定为
# 敏感文件并直接拒绝归档，错误码 HK-PROJECT-SECRET-FILE）。本地流水线统一产出
# unsigned HAP，签名由云构建平台、DevEco Studio 或自有 AGC 证书完成；不要为了过
# 检测去伪装/改名证书。历史脚本 scripts/sign_hap.sh（-compatibleVersion 12）已移除，
# 它签出的 HAP 与当前 API 26 / compatibleVersion 26 产物不符。
mkdir -p "$(dirname "$OUT_HAP")"
cp "$UNSIGNED" "$OUT_HAP"
SIGNED=0

echo "==> [3/5] pack.info / module.json 双向核对"
python3 - "$UNSIGNED" <<'PY'
import os, sys, json, zipfile
z = zipfile.ZipFile(sys.argv[1])
p = json.loads(z.read('pack.info'))['summary']['app']
m = json.loads(z.read('module.json'))['app']
ec, en = os.environ['EXPECT_CODE'], os.environ['EXPECT_NAME']
print('pack.info   :', p['bundleName'], p['version'])
print('module.json :', m['bundleName'], m['versionCode'], m['versionName'])
assert p['bundleName'] == m['bundleName'] == 'com.yinzhan.music'
assert str(p['version']['code']) == str(m['versionCode']) == ec
assert str(m['versionName']) == en
print('版本核对通过（期望 %s / %s）' % (ec, en))
PY

echo "==> [4/5] 签名后 profile 的 bundle-name"
if [ "$SIGNED" = "1" ]; then
  PROFILE="${OUT_HAP%.hap}-profile.p7b"
  java -jar "$OHOS_SDK_LIB/hap-sign-tool.jar" verify-profile -inFile "$PROFILE" -outFile /tmp/yinzhan-verify.json >/dev/null 2>&1
  python3 - <<'PY'
import json
d = json.load(open('/tmp/yinzhan-verify.json'))
print('verifiedPassed =', d['verifiedPassed'], '| bundle-name =', d['content']['bundle-info']['bundle-name'])
assert d['verifiedPassed'] is True
assert d['content']['bundle-info']['bundle-name'] == 'com.yinzhan.music'
PY
else
  echo "未签名，跳过 profile 校验（bundle-name 已在 [3/5] 由 module.json 核对）"
fi

echo "==> [5/5] 资源表关键词 + selfcheck"
python3 - "$UNSIGNED" <<'PY'
import sys, zipfile
b = zipfile.ZipFile(sys.argv[1]).read('resources.index')
print('「音栈」出现', b.count('音栈'.encode()), '次；「洛雪」出现', b.count('洛雪'.encode()), '次')
assert b.count('音栈'.encode()) > 0 and b.count('洛雪'.encode()) == 0
PY
python3 scripts/selfcheck.py . | tail -3

echo
echo "全部通过。产物：$OUT_HAP ($(stat -c %s "$OUT_HAP") 字节)"
