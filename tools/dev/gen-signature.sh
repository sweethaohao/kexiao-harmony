#!/usr/bin/env bash
# =============================================================================
# 课晓 · 生成本地调试签名材料（离线，不需要华为账号）
# -----------------------------------------------------------------------------
# 背景：
#   DevEco Studio 点「运行」时，如果 build-profile.json5 里没有签名配置，
#   hvigor 只会产出 entry-default-unsigned.hap（未签名），装到设备上必然失败：
#       Install Failed ... error: install sign info inconsistent.  (code 9568332)
#
#   官方解法是在 DevEco 里用「自动签名」，但那要登录华为开发者账号。
#   本脚本用 SDK 自带的 OpenHarmony 调试证书，在本地把三样东西签出来：
#       signature/kexiao.p12          ← 存放应用私钥的 keystore
#       signature/kexiao_app.cer      ← 由 CA 签发的应用证书链
#       signature/kexiao_debug.p7b    ← 调试用 profile（绑定包名 + 设备 UDID）
#   然后 build-profile.json5 指向它们即可，全程离线。
#
# 用法：
#   bash tools/dev/gen-signature.sh            # 生成（已存在则跳过）
#   bash tools/dev/gen-signature.sh --force    # 强制重新生成
#
# 本脚本一次做四件事：
#   1. 生成 signature/ 下的 keystore / 应用证书链 / 调试 profile
#   2. 生成 signature/material/（加密口令所需的密钥材料）
#   3. 把口令密文回写进 build-profile.json5
#   4. 让 hvigor 产出「已签名」的 HAP，DevEco 点运行与命令行走同一份材料，签名不会再冲突
#
# ⚠️ 重要：
#   profile 里绑定了「当前连接设备的 UDID」。换设备（换模拟器实例 / 换真机）
#   必须重新生成，否则装不上。
#   重新生成后证书会变，若设备上已装有同名旧应用，要先卸载：
#       hdc uninstall com.sweethaohao.kexiao
# =============================================================================
set -euo pipefail

DEVECO_HOME="${DEVECO_HOME:-G:/DevEco Studio}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SIGN_DIR="${SIGN_DIR:-$PROJECT_DIR/signature}"

JAVA="$DEVECO_HOME/jbr/bin/java.exe"
HDC="$DEVECO_HOME/sdk/default/openharmony/toolchains/hdc.exe"
LIB="$DEVECO_HOME/sdk/default/openharmony/toolchains/lib"
KS_SRC="$LIB/OpenHarmony.p12"
KSPWD="123456"
BUNDLE="com.sweethaohao.kexiao"

hdc() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" "$HDC" "$@"; }

FORCE=0
for arg in "$@"; do
  [ "$arg" = "--force" ] && FORCE=1
done

if [ -f "$SIGN_DIR/kexiao_debug.p7b" ] && [ "$FORCE" = "0" ]; then
  echo "✓ 签名材料已存在，跳过：$SIGN_DIR"
  echo "  （要重新生成请加 --force，但注意需先卸载设备上的旧应用）"
  exit 0
fi

for f in "$JAVA" "$HDC" "$KS_SRC"; do
  [ -f "$f" ] || { echo "✗ 找不到：$f（请检查 DEVECO_HOME）" >&2; exit 1; }
done

# --- 取设备 UDID：bm get -u 会输出提示行 + UDID 行，按 64 位十六进制抓 ---
UDID="$(hdc shell "bm get -u" | tr -d '\r' \
  | awk 'length($0) == 64 && $0 ~ /^[0-9A-Fa-f]+$/ { print; exit }')"
[ -n "$UDID" ] || { echo "✗ 没有检测到设备，请先在 DevEco 里启动模拟器" >&2; exit 1; }
echo "设备 UDID: $UDID"

mkdir -p "$SIGN_DIR"
cd "$SIGN_DIR"
rm -f kexiao.p12 kexiao_app.cer kexiao_debug.p7b profile.json

# --- 1) keystore：应用私钥在里面（SDK 自带的公开测试密钥，口令固定 123456） ---
cp "$KS_SRC" kexiao.p12

# --- 2) 拆出根 CA 与中间 CA（keystore 里那本应用证书是自签名的，不能用） ---
csplit -s -f _ca_ "$LIB/OpenHarmonyProfileDebug.pem" '/BEGIN CERTIFICATE/' '{*}' 2>/dev/null || true
cp _ca_01 root_ca.cer
cp _ca_02 sub_ca.cer

# --- 3) 用 CA 签发应用证书链（客户端设备只认"能被 CA 验证"的链） ---
"$JAVA" -jar "$LIB/hap-sign-tool.jar" generate-app-cert \
  -keyAlias "openharmony application release" -keyPwd "$KSPWD" \
  -issuer "C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=OpenHarmony Application CA" \
  -issuerKeyAlias "openharmony application ca" -issuerKeyPwd "$KSPWD" \
  -subject "C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=OpenHarmony Application Release" \
  -validity 3650 -signAlg SHA384withECDSA \
  -rootCaCertFile root_ca.cer -subCaCertFile sub_ca.cer \
  -keystoreFile "$KS_SRC" -keystorePwd "$KSPWD" \
  -outForm certChain -outFile kexiao_app.cer

rm -f _ca_* root_ca.cer sub_ca.cer

# --- 4) 生成 profile 并签名成 p7b（绑定包名 + 设备 UDID + 开发证书） ---
python - "$LIB" "$UDID" "$BUNDLE" <<'PY'
import json, sys, time, pathlib
lib, udid, bundle = sys.argv[1], sys.argv[2], sys.argv[3]
tpl = json.load(open(lib + '/UnsgnedDebugProfileTemplate.json', encoding='utf-8'))
chain = pathlib.Path('kexiao_app.cer').read_text(encoding='utf-8')
# 只取第一段（叶子证书）作为 development-certificate，与签名所用证书保持一致
leaf = chain.split('-----END CERTIFICATE-----')[0] + '-----END CERTIFICATE-----\n'
now = int(time.time())
tpl['validity'] = {'not-before': now - 86400, 'not-after': now + 31536000}
tpl['bundle-info']['bundle-name'] = bundle
tpl['bundle-info']['development-certificate'] = leaf
tpl['debug-info']['device-ids'] = [udid]
json.dump(tpl, open('profile.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print('profile.json -> bundle=%s, device=%s...' % (bundle, udid[:16]))
PY

"$JAVA" -jar "$LIB/hap-sign-tool.jar" sign-profile -mode localSign \
  -keyAlias "openharmony application profile debug" \
  -profileCertFile "$LIB/OpenHarmonyProfileDebug.pem" \
  -inFile profile.json -outFile kexiao_debug.p7b \
  -keystoreFile "$KS_SRC" -keyPwd "$KSPWD" -keystorePwd "$KSPWD" \
  -signAlg SHA256withECDSA

rm -f profile.json

# --- 5) 生成「加密口令」所需的 material，并把密文回写 build-profile.json5 ---------
# hvigor 不接受明文口令，只认它自己 AES-GCM 加密后的十六进制串（长度 ≥ 32）；
# 而这段密文又依赖 signature/material/ 里的密钥材料 —— 两者必须成对生成。
# 所以放在这里一起做：clone 之后只要跑一次本脚本，就恢复成「可构建 + 可安装」的状态。
NODE_BIN="${NODE_BIN:-$DEVECO_HOME/tools/node/node.exe}"
[ -x "$NODE_BIN" ] || NODE_BIN="node"
PWD_TOOL="$PROJECT_DIR/tools/dev/hvigor-signing-pwd.mjs"
CIPHER="$("$NODE_BIN" "$PWD_TOOL" "$KSPWD" "$SIGN_DIR" | tail -1)"
[ "${#CIPHER}" -ge 32 ] || { echo "✗ 生成签名口令密文失败，请检查 $PWD_TOOL" >&2; exit 1; }

python - "$PROJECT_DIR/build-profile.json5" "$CIPHER" <<'PY'
import re, sys, pathlib
path = pathlib.Path(sys.argv[1])
cipher = sys.argv[2]
text = path.read_text(encoding='utf-8')
for key in ('storePassword', 'keyPassword'):
    text, n = re.subn(r'("%s"\s*:\s*")[^"]*(")' % key,
                      lambda m: m.group(1) + cipher + m.group(2), text, count=1)
    if n != 1:
        print('✗ build-profile.json5 里没找到 %s 字段' % key, file=sys.stderr)
        sys.exit(1)
path.write_text(text, encoding='utf-8')
print('build-profile.json5 的 storePassword / keyPassword 已更新为密文')
PY

echo "✓ 签名材料已生成：$SIGN_DIR"
