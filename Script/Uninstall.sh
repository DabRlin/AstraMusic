#!/usr/bin/env bash
#
# AstraMusic 完全卸载
#
# 把这台 Mac 上的 AstraMusic 清得干干净净 —— 应用本体、资料库、偏好、缓存、
# 旧版本遗留的沙盒容器，以及钥匙串里的酷狗登录令牌 —— 做到「像从没装过一样」。
#
# 用法：
#   Script/Uninstall.sh            交互式，删之前会确认
#   Script/Uninstall.sh --yes      不再询问
#   Script/Uninstall.sh --dry-run  只打印会删除什么，不实际删除
#   Script/Uninstall.sh --help
#
# 幂等：不存在的路径会被跳过，重复运行无副作用。不需要 sudo。
#
# 另外两个脚本：clean_data_all.sh（只清数据，保留应用）、clean_cache.sh（只清缓存）。

set -u

# 共用定义（身份、落盘清单、say/run/confirm 等）都在 lib/common.sh，
# 三个脚本共用一份，避免路径清单漂移。
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "${SCRIPT_DIR}/lib/common.sh"

# ───────────────────────────── 参数 ─────────────────────────────

usage() {
  cat <<EOF
AstraMusic 完全卸载

用法: $(basename "$0") [选项]

选项:
  -y, --yes       不询问，直接执行
      --dry-run   只显示会删除的内容，不实际删除
  -h, --help      显示本帮助
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)  ASSUME_YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf '未知参数: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ──────────────────────────── 开场 ────────────────────────────
say "AstraMusic 完全卸载"
say "==================="
say ""
if [ "$DRY_RUN" -eq 1 ]; then
  say "模式: 试运行（不会删除任何东西）"
  say ""
fi
say "将尝试清除："
say "  · 应用本体        /Applications/${APP_NAME}.app"
say "  · 资料库与缓存    ~/Library/{Application Support,Caches,HTTPStorages,…}/${APP_NAME}"
say "  · 偏好设置        ~/Library/Preferences/${BUNDLE_ID}.plist"
say "  · 遗留沙盒容器    ~/Library/Containers/${BUNDLE_ID}（旧版本留下的）"
say "  · 登录令牌        钥匙串中的 ${KEYCHAIN_SERVICE} / ${KEYCHAIN_ACCOUNT}"
say ""

if ! confirm "确定要继续吗？"; then
  say "已取消，未做任何改动。"
  exit 0
fi
say ""

# ───────────────────── 1. 退出运行中的进程 ─────────────────────
say "[1/7] 退出正在运行的进程"
quit_app_processes

# ───────────────────────── 2. Homebrew cask ─────────────────────────
say "[2/7] 检查是否由 Homebrew 安装"
if command -v brew >/dev/null 2>&1 && brew list --cask --versions "$BREW_CASK" >/dev/null 2>&1; then
  say "  检测到 Homebrew cask，交给 brew 卸载（避免留下 Caskroom 记录）"
  run brew uninstall --cask "$BREW_CASK" >/dev/null 2>&1 \
    || warn "brew uninstall 未成功，稍后会直接删除应用本体"
else
  say "  未通过 Homebrew cask 安装，跳过"
fi

# ────────────────────────── 3. 应用本体 ──────────────────────────
say "[3/7] 删除应用本体"
for path in "${APP_PATHS[@]}"; do
  remove_path "$path"
done

# ───────────────────────── 4. 资料库与缓存 ─────────────────────────
say "[4/7] 删除资料库与缓存"
for path in "${CACHE_PATHS[@]}" "${STATE_PATHS[@]}"; do
  remove_path "$path"
done

# ────────────────────────── 5. 偏好设置 ──────────────────────────
say "[5/7] 删除偏好设置"
# 走 defaults 是为了让 cfprefsd 里的缓存副本一起失效
if [ "$DRY_RUN" -eq 1 ]; then
  printf '    [dry-run] defaults delete %s\n' "$BUNDLE_ID"
else
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
fi
for path in "${PREF_PATHS[@]}"; do
  remove_path "$path"
done
# ByHost 变体（本 app 不用，保险起见）
for path in "${HOME_DIR}/Library/Preferences/ByHost/${BUNDLE_ID}."*.plist; do
  if [ -e "$path" ]; then
    remove_path "$path"
  fi
done

# ─────────────────────────── 6. 钥匙串 ───────────────────────────
say "[6/7] 删除钥匙串中的登录令牌"
if security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1; then
  say "  删除 ${KEYCHAIN_SERVICE} / ${KEYCHAIN_ACCOUNT}"
  run security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1 \
    || warn "无法自动删除，见文末说明"
else
  say "  未找到条目（可能已删除）"
fi

# ───────────────────── 7. 反注册 + 残留复查 ─────────────────────
say "[7/7] 反注册并复查残留"
if [ -x "$LSREGISTER" ]; then
  for path in "${APP_PATHS[@]}"; do
    if [ -e "$path" ]; then
      run "$LSREGISTER" -u "$path" >/dev/null 2>&1 || true
    fi
  done
fi

say ""
say "复查 ~/Library 下的残留："
LEFT="$(find "${HOME_DIR}/Library" -maxdepth 4 -iname "*${APP_NAME}*" 2>/dev/null)"
if [ -z "$LEFT" ]; then
  say "  （无）"
else
  printf '%s\n' "$LEFT" | while IFS= read -r line; do
    say "  $line"
  done
fi

# ──────────────────────────── 结束 ────────────────────────────
say ""
if [ "$DRY_RUN" -eq 1 ]; then
  say "试运行结束 —— 以上是真正执行时会删除的内容。"
else
  say "完成。AstraMusic 及其数据已从这台 Mac 上移除。"
fi
say ""
say "说明："
say "  · 若「复查」仍有残留、或钥匙串条目删不掉，多半是权限或系统保护所致，可手动处理："
say "      钥匙串：打开「钥匙串访问」搜索 ${BUNDLE_ID} 删除对应条目"
say "      文件：用 Finder 删除，或 sudo rm -rf <路径>"
say "  · 用 Homebrew 安装的话，也可以直接：brew uninstall --cask --zap ${BREW_CASK}"
