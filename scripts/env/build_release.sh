#!/usr/bin/env bash
# =============================================================================
# 音栈完整交付流水线：基线复核 → 干净构建 → 签名 → 验签 → 版本核对 → 静态自检
# 基线：v2.48（59 / 2.48）；旧 v2.39 基线已作废，仅存档于 archive/baseline/legacy/
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
OUT_HAP="${2:-$PROJECT_DIR/build/音栈-v1.0-signed.hap}"
mkdir -p "$(dirname "$OUT_HAP")"
cd "$PROJECT_DIR"

echo "==> [0/5] 基线复核（v2.48 / 59，禁止移动/删除/覆盖）"
BASELINE_HAP="$PROJECT_DIR/archive/baseline/音栈-v2.48-基线.hap"
[ -f "$BASELINE_HAP" ] || { echo "基线 HAP 缺失，中止构建：$BASELINE_HAP"; exit 1; }
BASE_SHA="$(sha256sum "$BASELINE_HAP" | awk '{print $1}')"
[ "$BASE_SHA" = "b8b7e7b125da2a2e430c7704579689424b308a6747a2ed2fac0d9a6c71e52741" ] || {
  echo "基线 HAP 哈希不符，中止构建：$BASE_SHA"; exit 1;
}
echo "基线 HAP SHA256 = $BASE_SHA（一致）"

echo "==> [1/5] 干净构建（release）"
rm -rf entry/build
hvigorw assembleHap --mode module -p product=default -p buildMode=release --no-daemon | tee /tmp/yinzhan-build.log
grep -q "BUILD SUCCESSFUL" /tmp/yinzhan-build.log || { echo "构建失败"; exit 1; }
UNSIGNED="entry/build/default/outputs/default/entry-default-unsigned.hap"
[ -s "$UNSIGNED" ] || { echo "未找到 unsigned HAP"; exit 1; }

echo "==> [2/5] 签名 + verify-app"
# hvigor 的 clean/assemble 过程会清掉工程根 build/，这里必须重建输出目录，
# 否则 hap-sign-tool 会报 "Write zip file failed ... (No such file or directory)"。
mkdir -p "$(dirname "$OUT_HAP")"
# 源码工程包**不带任何签名材料**（云构建平台会把 .cer / .p12 / .p7b / .pem 判定为
# 敏感文件并直接拒绝归档，错误码 HK-PROJECT-SECRET-FILE）。没有本地材料时只出
# unsigned HAP，由云平台或 DevEco 自动签名；不要为了过检测去伪装/改名证书。
if [ -f signing/app-chain.pem ] && [ -f signing/profile.p7b ]; then
  bash scripts/sign_hap.sh "$UNSIGNED" "$OUT_HAP" | tee /tmp/yinzhan-sign.log
  grep -q "verify-app success" /tmp/yinzhan-sign.log || { echo "验签失败"; exit 1; }
  SIGNED=1
else
  echo "未找到 signing/app-chain.pem 或 signing/profile.p7b：跳过本地签名。"
  echo "源码包不含签名材料（云构建平台禁止归档证书）；云端构建由平台签名，本地产物为 unsigned HAP。"
  cp "$UNSIGNED" "$OUT_HAP"
  SIGNED=0
fi

echo "==> [3/5] pack.info / module.json 双向核对"
python3 - "$UNSIGNED" <<'PY'
import sys, json, zipfile
z = zipfile.ZipFile(sys.argv[1])
p = json.loads(z.read('pack.info'))['summary']['app']
m = json.loads(z.read('module.json'))['app']
print('pack.info   :', p['bundleName'], p['version'])
print('module.json :', m['bundleName'], m['versionCode'], m['versionName'])
assert p['bundleName'] == m['bundleName'] == 'com.yinzhan.music'
assert p['version']['code'] == m['versionCode'] == 67
assert p['version']['name'] == m['versionName'] == '1.0'
print('版本核对通过')
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
python3 scripts/selfcheck.py | tail -3

echo
echo "全部通过。产物：$OUT_HAP ($(stat -c %s "$OUT_HAP") 字节)"
