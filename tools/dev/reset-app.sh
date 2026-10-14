#!/usr/bin/env bash
# =============================================================================
# 课晓 · 把设备恢复到"全新安装"状态，用来反复测首次启动 / 初次导入
# -----------------------------------------------------------------------------
# 为什么需要它？
#   应用一旦装过、跑过，设备上就留下了安装记录和应用数据目录。
#   想验证"用户第一次打开应用"看到什么，必须先把这些清掉，
#   否则测出来的永远是"第二次以后"的行为。
#
# 三种清法（从轻到重）：
#   bm clean -c          只清缓存，保留数据        —— 基本没用，测首次启动别用它
#   bm clean -d          清掉应用数据目录          —— 应用还在，数据归零
#   uninstall            彻底卸载（默认连数据一起删）—— 最接近"全新安装"，推荐
#
# 用法：
#   bash tools/dev/reset-app.sh             # 清数据 + 重启应用
#   bash tools/dev/reset-app.sh --fresh     # 卸载 → 重新编译签名安装启动（最干净）
#   bash tools/dev/reset-app.sh --shot      # 附带截一张图，存到 _signing/
# =============================================================================
set -uo pipefail

DEVECO_HOME="${DEVECO_HOME:-G:/DevEco Studio}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SIGN_DIR="${SIGN_DIR:-$(cd "$PROJECT_DIR/.." && pwd)/_signing}"
HDC="$DEVECO_HOME/sdk/default/openharmony/toolchains/hdc.exe"
BUNDLE="com.sweethaohao.kexiao"
ABILITY="EntryAbility"

hdc() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" "$HDC" "$@"; }

FRESH=0
SHOT=0
for arg in "$@"; do
  case "$arg" in
    --fresh) FRESH=1 ;;
    --shot) SHOT=1 ;;
  esac
done

# --- 0) 设备在不在？不在就直接说清楚，别报一堆看不懂的错 ---
if ! "$HDC" list targets 2>/dev/null | grep -q .; then
  echo "✗ 没有检测到设备。请先在 DevEco Studio 里启动模拟器，再重跑本脚本。" >&2
  exit 1
fi

if [ "$FRESH" = "1" ]; then
  # ---------------------------------------------------------------------------
  # 彻底重来：卸载（连数据）→ 走 deploy.sh 重新编译签名安装并启动
  # ---------------------------------------------------------------------------
  echo "=== 1/2 卸载 $BUNDLE（含应用数据） ==="
  OUT="$(hdc uninstall "$BUNDLE" 2>&1 | tail -1)"
  case "$OUT" in
    *success*) echo "✓ 已卸载" ;;
    *) echo "· 卸载未成功（可能本来就没装）：$OUT" ;;
  esac

  echo "=== 2/2 重新编译 → 签名 → 安装 → 启动 ==="
  # deploy.sh 会把 build/profile 一并处理好
  bash "$SCRIPT_DIR/deploy.sh" || exit 1
  echo "✓ 现在是「全新安装后第一次打开」的状态"
else
  # ---------------------------------------------------------------------------
  # 清数据重启：应用不重装，只把数据目录清空
  # ---------------------------------------------------------------------------
  echo "=== 1/3 清除应用数据目录 ==="
  hdc shell "bm clean -d -n $BUNDLE" 2>&1 | tail -1
  echo "=== 2/3 结束进程 ==="
  hdc shell "aa force-stop $BUNDLE" >/dev/null 2>&1 || true
  echo "=== 3/3 重新启动 ==="
  hdc shell "aa start -a $ABILITY -b $BUNDLE" 2>&1 | tail -1
  echo "✓ 应用数据已归零并重新启动"
  echo "  提示：本项目目前还没做持久化，bm clean -d 暂时看不出差别——"
  echo "        真正想测「初次导入」，请用 --fresh（卸载重装）。"
fi

# --- 可选：截图 ---
if [ "$SHOT" = "1" ]; then
  sleep 5
  mkdir -p "$SIGN_DIR"
  cd "$SIGN_DIR"
  hdc shell "snapshot_display -f /data/local/tmp/kexiao.jpeg" >/dev/null 2>&1
  hdc file recv /data/local/tmp/kexiao.jpeg kexiao.jpeg >/dev/null 2>&1
  echo "✓ 截图：$SIGN_DIR/kexiao.jpeg"
fi
