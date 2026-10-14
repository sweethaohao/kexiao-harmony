#!/usr/bin/env bash
# =============================================================================
# 课晓 · 一键部署到鸿蒙模拟器 / 真机
# -----------------------------------------------------------------------------
# 为什么需要这个脚本？
#   DevEco Studio 的「运行」按钮会走"自动签名"，需要登录华为账号；
#   而命令行编译出来的 HAP 是未签名的，直接 hdc install 会失败。
#   这个脚本用 SDK 自带的 OpenHarmony 调试证书在本地把 HAP 签好，
#   再安装到设备上 —— 全程离线，不依赖账号。
#
# 用法：
#   bash tools/dev/deploy.sh              # 编译 + 签名 + 安装 + 启动
#   bash tools/dev/deploy.sh --shot       # 额外截一张图到 _signing/
#   bash tools/dev/deploy.sh --setup      # 首次使用：生成签名材料（只跑一次）
#
# 可通过环境变量覆盖路径：
#   DEVECO_HOME   DevEco Studio 安装目录（默认 G:/DevEco Studio）
#   SIGN_DIR      签名材料目录（默认 <工程根>/../_signing）
# =============================================================================
set -euo pipefail

DEVECO_HOME="${DEVECO_HOME:-G:/DevEco Studio}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SIGN_DIR="${SIGN_DIR:-$(cd "$PROJECT_DIR/.." && pwd)/_signing}"

NODE="$DEVECO_HOME/tools/node/node.exe"
HVIGOR="$DEVECO_HOME/tools/hvigor/bin/hvigorw.js"
JAVA="$DEVECO_HOME/jbr/bin/java.exe"
HDC="$DEVECO_HOME/sdk/default/openharmony/toolchains/hdc.exe"
LIB="$DEVECO_HOME/sdk/default/openharmony/toolchains/lib"
KS="$LIB/OpenHarmony.p12"
KSPWD="123456"

# hdc 的路径参数会被 Git Bash 的路径转换弄坏，统一关掉
hdc() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" "$HDC" "$@"; }

# -----------------------------------------------------------------------------
# 首次使用：用 SDK 自带的 OpenHarmony 调试证书生成应用证书链 + 调试 profile
# -----------------------------------------------------------------------------
setup_signing() {
  mkdir -p "$SIGN_DIR"
  cd "$SIGN_DIR"
  local UDID
  # bm get -u 的输出是两行：第一行提示语，第二行才是 udid，所以按"64 位十六进制"来抓
  UDID="$(hdc shell "bm get -u" | tr -d '\r' \
    | awk 'length($0) == 64 && $0 ~ /^[0-9A-Fa-f]+$/ { print; exit }')"
  if [ -z "$UDID" ]; then
    echo "✗ 没有检测到设备，请先在 DevEco 里启动模拟器" >&2
    exit 1
  fi
  echo "设备 UDID: $UDID"

  # 从 SDK 的 profile 证书文件里拆出 根CA / 中间CA
  csplit -s -f pc_ "$LIB/OpenHarmonyProfileDebug.pem" '/BEGIN CERTIFICATE/' '{*}' 2>/dev/null || true
  cp pc_01 root_ca.cer
  cp pc_02 sub_ca.cer

  # 用 CA 签发"应用证书链"（keystore 里那本证书是自签名的，不能直接用）
  "$JAVA" -jar "$LIB/hap-sign-tool.jar" generate-app-cert \
    -keyAlias "openharmony application release" -keyPwd "$KSPWD" \
    -issuer "C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=OpenHarmony Application CA" \
    -issuerKeyAlias "openharmony application ca" -issuerKeyPwd "$KSPWD" \
    -subject "C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=OpenHarmony Application Release" \
    -validity 3650 -signAlg SHA384withECDSA \
    -rootCaCertFile root_ca.cer -subCaCertFile sub_ca.cer \
    -keystoreFile "$KS" -keystorePwd "$KSPWD" \
    -outForm certChain -outFile app_cert_chain.cer

  # 生成调试 profile（绑定本机 bundleName + 设备 UDID）
  python - "$LIB" "$UDID" <<'PY'
import json, sys, time, pathlib
lib, udid = sys.argv[1], sys.argv[2]
tpl = json.load(open(lib + '/UnsgnedDebugProfileTemplate.json', encoding='utf-8'))
leaf = pathlib.Path('app_cert_chain.cer').read_text(encoding='utf-8')
# 取证书链的第一段作为"开发证书"，与后面签名用的证书保持一致
leaf = leaf.split('-----END CERTIFICATE-----')[0] + '-----END CERTIFICATE-----\n'
now = int(time.time())
tpl['validity'] = {'not-before': now - 86400, 'not-after': now + 31536000}
tpl['bundle-info']['bundle-name'] = 'com.sweethaohao.kexiao'
tpl['bundle-info']['development-certificate'] = leaf
tpl['debug-info']['device-ids'] = [udid]
json.dump(tpl, open('profile.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print('profile.json 已生成 -> bundle-name=com.sweethaohao.kexiao, device=' + udid[:16] + '...')
PY

  "$JAVA" -jar "$LIB/hap-sign-tool.jar" sign-profile -mode localSign \
    -keyAlias "openharmony application profile debug" \
    -profileCertFile "$LIB/OpenHarmonyProfileDebug.pem" \
    -inFile profile.json -outFile profile.p7b \
    -keystoreFile "$KS" -keyPwd "$KSPWD" -keystorePwd "$KSPWD" \
    -signAlg SHA256withECDSA
  echo "✓ 签名材料就绪：$SIGN_DIR"
}

# -----------------------------------------------------------------------------
# 主流程
# -----------------------------------------------------------------------------
SHOT=0
for arg in "$@"; do
  case "$arg" in
    --setup) setup_signing; exit 0 ;;
    --shot) SHOT=1 ;;
  esac
done

if [ ! -f "$SIGN_DIR/profile.p7b" ]; then
  echo "首次运行，先生成签名材料…"
  setup_signing
fi

echo "=== 1/4 编译 ==="
cd "$PROJECT_DIR"
DEVECO_SDK_HOME="$DEVECO_HOME/sdk" "$NODE" "$HVIGOR" \
  --mode module -p product=default assembleHap --no-daemon 2>&1 \
  | grep -E "WARN|ERROR|BUILD" || true

HAP="$PROJECT_DIR/entry/build/default/outputs/default/entry-default-unsigned.hap"
if [ ! -f "$HAP" ]; then
  echo "✗ 编译产物不存在：$HAP" >&2
  exit 1
fi

echo "=== 2/4 本地签名 ==="
cd "$SIGN_DIR"
"$JAVA" -jar "$LIB/hap-sign-tool.jar" sign-app -mode localSign \
  -keyAlias "openharmony application release" \
  -appCertFile app_cert_chain.cer -profileFile profile.p7b \
  -inFile "$HAP" -outFile entry-signed.hap \
  -keystoreFile "$KS" -keyPwd "$KSPWD" -keystorePwd "$KSPWD" \
  -signAlg SHA256withECDSA 2>&1 | grep -E "INFO - sign|ERROR" || true

echo "=== 3/4 安装 ==="
hdc install -r entry-signed.hap 2>&1 | tail -1

echo "=== 4/4 启动 ==="
hdc shell aa force-stop com.sweethaohao.kexiao >/dev/null 2>&1 || true
hdc shell aa start -a EntryAbility -b com.sweethaohao.kexiao 2>&1 | tail -1

if [ "$SHOT" = "1" ]; then
  sleep 5
  # 注意：因为关闭了 Git Bash 的路径转换，接收端要用相对路径，
  # 否则本地绝对路径会被当成设备端路径。
  cd "$SIGN_DIR"
  hdc shell "snapshot_display -f /data/local/tmp/kexiao.jpeg" >/dev/null 2>&1
  hdc file recv /data/local/tmp/kexiao.jpeg kexiao.jpeg 2>&1 | tail -1
  echo "✓ 截图：$SIGN_DIR/kexiao.jpeg"
fi
