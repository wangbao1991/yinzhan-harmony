#!/usr/bin/env bash
# =============================================================================
# 打「可构建编译的源码工程包」：干净、无本机残留、解压即可 build_release.sh
# 用法：
#   bash scripts/env/make_source_zip.sh                       # 输出到上层目录
#   bash scripts/env/make_source_zip.sh /tmp/out.zip          # 指定路径
#
# 打包内容：AppScope / entry/src / hvigor / signing / scripts / docs /
#           archive/baseline 下的基线 HAP（build_release.sh 的 [0/5] 要用）/
#           根级配置与文档
# 排除：.env.local（本机路径）、build/、entry/build/、.hvigor/、
#       archive/snapshots、archive/hap、archive/diagrams、__pycache__、*.log
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PARENT_DIR="$(cd "$PROJECT_DIR/.." && pwd)"
NAME="$(basename "$PROJECT_DIR")"

VERSION="$(sed -n 's/.*"versionName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PROJECT_DIR/AppScope/app.json5" | head -1)"
OUT="${1:-$PARENT_DIR/${NAME}-v${VERSION}-源码工程.zip}"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

# 必须先剔除构建产物，否则 zip 会把上一轮的 entry/build 一起卷进去
rm -rf "$PROJECT_DIR/entry/build" "$PROJECT_DIR/.hvigor" "$PROJECT_DIR/scripts/__pycache__"

cd "$PARENT_DIR"
zip -qr "$OUT" "$NAME" \
  -x "$NAME/.env.local" \
  -x "$NAME/build/*" \
  -x "$NAME/entry/build/*" \
  -x "$NAME/.hvigor/*" \
  -x "$NAME/.git/*" \
  -x "$NAME/archive/snapshots/*" \
  -x "$NAME/archive/hap/*" \
  -x "$NAME/archive/diagrams/*" \
  -x "$NAME/archive/baseline/legacy/*" \
  -x "$NAME/archive/baseline/*.zip" \
  -x "$NAME/archive/baseline/*.html" \
  -x "$NAME/archive/baseline/SHA256SUMS" \
  -x "$NAME/scripts/__pycache__/*" \
  -x "*.log" \
  -x "$NAME/signing/*" \
  -x "$NAME/archive/signing/*" \
  -x "*.cer" -x "*.p12" -x "*.p7b" -x "*.pem" -x "*.jks" -x "*.keystore" -x "*.csr"

echo "==> 打包完成：$OUT"
stat -c '大小：%s 字节' "$OUT"
sha256sum "$OUT"

echo "==> 内容自检"
python3 - "$OUT" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = z.namelist()
SENSITIVE = ('.cer', '.p12', '.p7b', '.pem', '.jks', '.keystore', '.csr')
bad = [n for n in names if ('/.env.local' in n or '/build/' in n or '/.hvigor/' in n
       or 'archive/snapshots' in n or 'archive/hap/' in n or '__pycache__' in n
       or '/signing/' in n or n.lower().endswith(SENSITIVE)
       or (n.endswith('.zip') and '/archive/baseline/' in n))]
need = ['AppScope/app.json5', 'entry/src/main/ets', 'build-profile.json5',
        'hvigorfile.ts', 'oh-package.json5', 'hvigor/hvigor-config.json5',
        'scripts/env/env.sh', 'scripts/env/setup_env_26.sh',
        'scripts/env/build_release.sh', 'scripts/env/make_source_zip.sh',
        'docs/编译环境重建指南（避坑版）.md',
        'archive/baseline/音栈-v2.48-基线.hap', 'AGENTS.md', 'README.md']
root = names[0].split('/')[0]
print('  条目数：', len(names))
print('  顶层目录：', root)
missing = [p for p in need if not any(n.rstrip('/').endswith('/' + p) or n.rstrip('/') == root + '/' + p for n in names)]
if bad:
    print('  [FAIL] 含不该打包的内容（构建残留 / 签名材料）：', bad[:5])
    print('         云构建平台会以 HK-PROJECT-SECRET-FILE 拒绝归档含证书的工程'); sys.exit(1)
if missing:
    print('  [FAIL] 缺关键文件：', missing); sys.exit(1)
print('  [OK] 无本机残留 / 无证书密钥材料、关键文件齐全（含基线 HAP，可直接跑 build_release.sh 或上传云构建）')
PY
