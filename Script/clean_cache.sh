#!/usr/bin/env bash
#
# AstraMusic 清理缓存（不动你的资料库）
#
# 只删可再生的缓存：
#   · app 自己的缓存目录（封面图的 HTTP 缓存、CFNetwork 存储）
#   · AVPlayer 播放时落下的流媒体临时分片（本 app 最大的一块临时文件）
#
# **不碰**这些东西：library.json（喜欢 / 最近播放 / 本地歌单）、偏好设置、
# 钥匙串里的登录令牌。清完仍是登录状态，最近播放和歌单都还在。
#
# 用法：
#   Script/clean_cache.sh                交互式（删之前确认）
#   Script/clean_cache.sh --yes          不再询问
#   Script/clean_cache.sh --dry-run      只打印会删什么
#   Script/clean_cache.sh --keep-media   只清 app 自己的缓存，不动 AVPlayer 的
#   Script/clean_cache.sh --help
#
# 幂等：不存在的路径会跳过，重复运行无副作用。不需要 sudo。
#
# 另两个脚本：clean_data_all.sh（清全部数据）、Uninstall.sh（连应用一起删）。

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "${SCRIPT_DIR}/lib/common.sh"

KEEP_MEDIA=0

usage() {
  cat <<EOF
AstraMusic 清理缓存（保留资料库 / 偏好 / 登录态）

用法: $(basename "$0") [选项]

选项:
  -y, --yes         不询问，直接执行
      --dry-run     只显示会删除的内容，不实际删除
      --keep-media  跳过 AVPlayer 的流媒体缓存（那是用户级共用目录）
  -h, --help        显示本帮助
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)     ASSUME_YES=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    --keep-media) KEEP_MEDIA=1 ;;
    -h|--help)    usage; exit 0 ;;
    *) printf '未知参数: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ──────────────────────────── 开场 ────────────────────────────
say "AstraMusic 清理缓存"
say "==================="
say ""
if [ "$DRY_RUN" -eq 1 ]; then
  say "模式: 试运行（不会删除任何东西）"
  say ""
fi

say "将清除（可再生，删了会重新下载 / 重建）："
say "  · app 缓存        ~/Library/{Caches,HTTPStorages,WebKit}/${BUNDLE_ID}"
if [ "$KEEP_MEDIA" -eq 1 ]; then
  say "  · AVPlayer 缓存   跳过（--keep-media）"
else
  say "  · AVPlayer 缓存   \$TMPDIR/MediaCache（播放落下的流媒体分片）"
fi
say ""
say "本脚本不会碰："
say "  · 喜欢 / 最近播放 / 本地歌单   ~/Library/Application Support/${APP_NAME}/library.json"
say "  · 偏好设置                     ~/Library/Preferences/${BUNDLE_ID}.plist"
say "  · 登录令牌                     钥匙串中的 ${KEYCHAIN_SERVICE} / ${KEYCHAIN_ACCOUNT}"
say ""

if ! confirm "确定要继续吗？"; then
  say "已取消，未做任何改动。"
  exit 0
fi
say ""

# 结束时用来报「释放了多少」
TO_CLEAN=("${CACHE_PATHS[@]}")
if MEDIA_PATH="$(media_cache_path)"; then
  TO_CLEAN+=("$MEDIA_PATH")
fi
BEFORE_KB="$(total_kb "${TO_CLEAN[@]}")"

# ───────────────────── 1. 退出运行中的进程 ─────────────────────
say "[1/3] 退出正在运行的进程"
quit_app_processes

# ─────────────────────────── 2. app 缓存 ───────────────────────────
say "[2/3] 删除 app 缓存"
for path in "${CACHE_PATHS[@]}"; do
  remove_path "$path"
done

# ──────────────────── 3. AVPlayer 流媒体缓存 ────────────────────
say "[3/3] 删除 AVPlayer 流媒体缓存"
clean_media_cache

# ──────────────────────────── 结束 ────────────────────────────
say ""
if [ "$DRY_RUN" -eq 1 ]; then
  say "试运行结束 —— 以上是真正执行时会删除的内容（约 $(human_kb "$BEFORE_KB")）。"
else
  say "完成，释放约 $(human_kb "$BEFORE_KB")。"
  say "喜欢 / 最近播放 / 本地歌单 / 登录态都没有动。"
fi
