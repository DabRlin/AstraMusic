#!/usr/bin/env bash
#
# AstraMusic 脚本的共用定义。被 Script/ 下的三个脚本 source：
#
#   Uninstall.sh        应用本体 + 全部数据（像从没装过）
#   clean_data_all.sh   全部数据，但保留应用本体（像刚装上）
#   clean_cache.sh      只清可再生缓存（保留资料库 / 偏好 / 登录态）
#
# 存在的理由是「app 的落盘清单只能有一份」：路径一变三处一起变，不会漂移。
# 这份清单同时要和 tap 仓库 Casks/astramusic.rb 的 `zap trash:` 对齐，改一处要改另一处。

if [ -z "${BASH_VERSION:-}" ]; then
  printf '这些脚本需要 bash，请这样运行：  bash <脚本路径>\n' >&2
  exit 2
fi

# ───────────────────────────── 身份 ─────────────────────────────
APP_NAME="AstraMusic"
BUNDLE_ID="com.dang.AstraMusic"
SIDECAR_NAME="AstraMusicSidecar"
BREW_CASK="astramusic"
# 与 Networking/SessionStore.swift 的 service / tokenAccount 保持一致
KEYCHAIN_SERVICE="com.dang.AstraMusic"
KEYCHAIN_ACCOUNT="kugou.token"

HOME_DIR="${HOME:?HOME 未设置}"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# ─────────────────────── app 的落盘清单 ───────────────────────
#
# 分两类，因为 clean_cache.sh 只删「缓存」：
#   · CACHE_PATHS — 可再生的缓存。删了只是重新下载 / 重建，丢不了用户内容。
#   · STATE_PATHS — 用户内容与身份。删了 = 退出登录、最近播放清空、本地歌单消失。
#
# （音频本身从不缓存，所以这里没有「音乐缓存」这种东西：每次播放都重新解析 CDN。）
APP_PATHS=(
  "/Applications/${APP_NAME}.app"
  "${HOME_DIR}/Applications/${APP_NAME}.app"
)

CACHE_PATHS=(
  "${HOME_DIR}/Library/Caches/${BUNDLE_ID}"          # 封面图的 URLCache（默认上限 20 MB）
  "${HOME_DIR}/Library/HTTPStorages/${BUNDLE_ID}"    # CFNetwork 的 cookie / 缓存 db
  "${HOME_DIR}/Library/WebKit/${BUNDLE_ID}"
)

STATE_PATHS=(
  "${HOME_DIR}/Library/Application Support/${APP_NAME}"   # library.json：喜欢 / 最近播放 / 本地歌单
  "${HOME_DIR}/Library/Application Scripts/${BUNDLE_ID}"
  "${HOME_DIR}/Library/Saved Application State/${BUNDLE_ID}.savedState"
  "${HOME_DIR}/Library/Containers/${BUNDLE_ID}"           # 旧版本沙盒时代留下的
  "${HOME_DIR}/Library/Logs/${APP_NAME}"
)

PREF_PATHS=(
  "${HOME_DIR}/Library/Preferences/${BUNDLE_ID}.plist"
)

# ───────────────────────────── 参数 ─────────────────────────────
DRY_RUN=0
ASSUME_YES=0

# ──────────────────────────── 小工具 ────────────────────────────
say()  { printf '%s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }

# 尊重 --dry-run 地执行一条命令
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '    [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  # 试运行不删任何东西，没有确认的必要；也让 --dry-run 可以无 TTY 跑
  [ "$DRY_RUN" -eq 1 ] && return 0
  printf '%s [y/N] ' "$1"
  read -r reply || return 1
  case "$reply" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# 删除一个存在的路径（文件 / 目录 / 符号链接）；不存在则静默跳过
remove_path() {
  local path="$1"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi
  say "  删除 $path"
  if [ -L "$path" ] || [ ! -d "$path" ]; then
    run rm -f -- "$path" || warn "无法删除: $path"
  else
    run rm -rf -- "$path" || warn "无法删除: $path（可能受系统保护，见文末说明）"
  fi
}

# 结束 AstraMusic 与 sidecar：先请它自己退，5 秒还在就强制。
# 删缓存必须在退出后做 —— 否则运行中的进程会一边删一边重建。
quit_app_processes() {
  local name found=0 _
  for name in "$APP_NAME" "$SIDECAR_NAME"; do
    if pgrep -x "$name" >/dev/null 2>&1; then
      say "  结束 $name"
      run pkill -x "$name" >/dev/null 2>&1 || true
      found=1
    fi
  done
  if [ "$found" -eq 0 ]; then
    say "  没有运行中的进程"
    return 0
  fi
  [ "$DRY_RUN" -eq 1 ] && return 0
  for _ in 1 2 3 4 5; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1 && ! pgrep -x "$SIDECAR_NAME" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  for name in "$APP_NAME" "$SIDECAR_NAME"; do
    if pgrep -x "$name" >/dev/null 2>&1; then
      run pkill -9 -x "$name" >/dev/null 2>&1 || true
    fi
  done
  return 0
}

# 一组路径的总占用（KB），用来报「释放了多少」
total_kb() {
  local total=0 path size
  for path in "$@"; do
    [ -e "$path" ] || continue
    size="$(du -sk "$path" 2>/dev/null | awk 'NR==1 {print $1}')"
    case "$size" in ''|*[!0-9]*) continue ;; esac
    total=$((total + size))
  done
  printf '%s' "$total"
}

human_kb() {
  local kb="${1:-0}"
  if [ "$kb" -ge 1048576 ]; then printf '%s GB' "$((kb / 1048576))"
  elif [ "$kb" -ge 1024 ]; then printf '%s MB' "$((kb / 1024))"
  else printf '%s KB' "$kb"
  fi
}

# ───────────────── AVPlayer 的流媒体缓存（特殊处理）─────────────────
#
# 本 app 最大的一块临时文件：沙盒时代实测 571 MB / 26,657 个文件
# （见 Docs/env-cleanup.md §4a）。取消沙盒后 NSTemporaryDirectory() 变成
# 用户级的 /var/folders/…/T/，于是它落在那里 —— 一个**所有 App 共用**的目录。
# 正因为它共用，Uninstall.sh 不整体清那个目录（会误伤别人的播放）。
#
# 只在 TMPDIR 看起来是常规 per-user 临时目录时才返回路径，避免异常环境下误删。
media_cache_path() {
  local tmp="${TMPDIR:-}"
  case "$tmp" in
    /var/folders/*|/private/var/folders/*) ;;
    /tmp|/tmp/*) ;;
    /private/tmp|/private/tmp/*) ;;
    *) return 1 ;;
  esac
  printf '%s/MediaCache' "${tmp%/}"
}

# 受 KEEP_MEDIA=1（--keep-media）控制
clean_media_cache() {
  local path
  if [ "${KEEP_MEDIA:-0}" -eq 1 ]; then
    say "  跳过（--keep-media）"
    return 0
  fi
  if ! path="$(media_cache_path)"; then
    say "  跳过：TMPDIR 不是常规的 per-user 临时目录"
    return 0
  fi
  if [ ! -e "$path" ]; then
    say "  没有可清理的（$path 不存在）"
    return 0
  fi
  say "  $path"
  say "  （播放时落下的流媒体分片，纯缓存；不在 AstraMusic 名下，别的 App 若在播放最多重新缓冲一次）"
  remove_path "$path"
}
