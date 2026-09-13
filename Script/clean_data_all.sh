#!/usr/bin/env bash
#
# AstraMusic 清空全部数据（保留应用本体）
#
# 效果等于「刚装上、还没登录」：资料库（喜欢 / 最近播放 / 本地歌单）、偏好设置、
# 缓存，以及钥匙串里的登录令牌全部清掉，只保留 /Applications/AstraMusic.app。
# 下次启动会重新注册设备，并且需要重新登录。
#
# 与 Uninstall.sh 的唯一区别：不动应用本体，也不动 Homebrew 的安装记录。
#
# 用法：
#   Script/clean_data_all.sh                 交互式（删之前确认）
#   Script/clean_data_all.sh --yes           不再询问
#   Script/clean_data_all.sh --dry-run       只打印会删什么
#   Script/clean_data_all.sh --keep-login    保留钥匙串令牌（清数据但仍保持登录）
#   Script/clean_data_all.sh --keep-media    跳过 AVPlayer 的流媒体缓存
#   Script/clean_data_all.sh --help
#
# 幂等：不存在的路径会跳过，重复运行无副作用。不需要 sudo。
#
# 另两个脚本：clean_cache.sh（只清缓存）、Uninstall.sh（连应用一起删）。

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "${SCRIPT_DIR}/lib/common.sh"

KEEP_MEDIA=0
KEEP_LOGIN=0

usage() {
  cat <<EOF
AstraMusic 清空全部数据（保留 app 本体）

用法: $(basename "$0") [选项]

选项:
  -y, --yes         不询问，直接执行
      --dry-run     只显示会删除的内容，不实际删除
      --keep-login  保留钥匙串里的登录令牌（其余数据照删）
      --keep-media  跳过 AVPlayer 的流媒体缓存（那是用户级共用目录）
  -h, --help        显示本帮助
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)     ASSUME_YES=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    --keep-login) KEEP_LOGIN=1 ;;
    --keep-media) KEEP_MEDIA=1 ;;
    -h|--help)    usage; exit 0 ;;
    *) printf '未知参数: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ──────────────────────────── 开场 ────────────────────────────
say "AstraMusic 清空全部数据"
say "======================="
say ""
if [ "$DRY_RUN" -eq 1 ]; then
  say "模式: 试运行（不会删除任何东西）"
  say ""
fi

say "将清除（等于「刚装上、还没登录」）："
say "  · 资料库          ~/Library/Application Support/${APP_NAME}（喜欢 / 最近播放 / 本地歌单）"
say "  · 缓存            ~/Library/{Caches,HTTPStorages,WebKit}/${BUNDLE_ID}"
say "  · 其它状态        ~/Library/{Application Scripts,Saved Application State,Logs,Containers}/${BUNDLE_ID}"
say "  · 偏好设置        ~/Library/Preferences/${BUNDLE_ID}.plist"
if [ "$KEEP_LOGIN" -eq 1 ]; then
  say "  · 登录令牌        保留（--keep-login）"
else
  say "  · 登录令牌        钥匙串中的 ${KEYCHAIN_SERVICE} / ${KEYCHAIN_ACCOUNT}"
fi
if [ "$KEEP_MEDIA" -eq 1 ]; then
  say "  · AVPlayer 缓存   跳过（--keep-media）"
else
  say "  · AVPlayer 缓存   \$TMPDIR/MediaCache（播放落下的流媒体分片）"
fi
say ""
say "保留不动："
say "  · 应用本体        /Applications/${APP_NAME}.app"
say ""

if ! confirm "确定要继续吗？"; then
  say "已取消，未做任何改动。"
  exit 0
fi
say ""

# 结束时用来报「释放了多少」
TO_CLEAN=("${CACHE_PATHS[@]}" "${STATE_PATHS[@]}" "${PREF_PATHS[@]}")
if MEDIA_PATH="$(media_cache_path)"; then
  TO_CLEAN+=("$MEDIA_PATH")
fi
BEFORE_KB="$(total_kb "${TO_CLEAN[@]}")"

# ───────────────────── 1. 退出运行中的进程 ─────────────────────
say "[1/6] 退出正在运行的进程"
quit_app_processes

# ─────────────────────────── 2. 缓存 ───────────────────────────
say "[2/6] 删除缓存"
for path in "${CACHE_PATHS[@]}"; do
  remove_path "$path"
done

# ──────────────────── 3. AVPlayer 流媒体缓存 ────────────────────
say "[3/6] 删除 AVPlayer 流媒体缓存"
clean_media_cache

# ──────────────────────── 4. 资料库 ────────────────────────
say "[4/6] 删除资料库与其它状态"
for path in "${STATE_PATHS[@]}"; do
  remove_path "$path"
done

# ─────────────────────── 5. 偏好设置 ───────────────────────
say "[5/6] 删除偏好设置"
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
say "[6/6] 删除钥匙串中的登录令牌"
if [ "$KEEP_LOGIN" -eq 1 ]; then
  say "  保留（--keep-login）"
elif security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1; then
  say "  删除 ${KEYCHAIN_SERVICE} / ${KEYCHAIN_ACCOUNT}"
  run security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1 \
    || warn "无法自动删除，见文末说明"
else
  say "  未找到条目（可能已删除）"
fi

# ───────────────────────── 残留复查 ─────────────────────────
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
  say "试运行结束 —— 以上是真正执行时会删除的内容（约 $(human_kb "$BEFORE_KB")）。"
else
  say "完成，释放约 $(human_kb "$BEFORE_KB")。"
  say "${APP_NAME}.app 保留在原处，下次启动需要重新登录。"
fi
say ""
say "说明：若「复查」仍有残留、或钥匙串条目删不掉，多半是权限或系统保护所致："
say "  · 钥匙串：打开「钥匙串访问」搜索 ${BUNDLE_ID} 删除对应条目"
say "  · 文件：用 Finder 删除，或 sudo rm -rf <路径>"
