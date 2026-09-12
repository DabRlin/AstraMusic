#!/bin/bash
#
# Builds a distributable AstraMusic.dmg: Release app + bundled sidecar + ad-hoc
# signature.
#
# Nothing here needs an Apple Developer account. The result is signed ad-hoc
# (`codesign -s -`), never notarized, so a downloaded copy arrives quarantined and
# the user must open it once via right-click -> Open. See Docs/packaging-plan.md.
#
# Prerequisites: Xcode, pnpm (npm i -g pnpm@9), and network access the first time
# (pkg fetches a Node base binary).
#
#   Tools/package.sh                 # sidecar + app + dmg
#   Tools/package.sh --skip-sidecar  # reuse Sidecar/bin/AstraMusicSidecar
#   Tools/package.sh --skip-build    # reuse the staged Release app
#
# Output: dist/AstraMusic-v<version>.dmg

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="AstraMusic"
SIDECAR_NAME="AstraMusicSidecar"
SIDECAR_TARGET="node18-macos-arm64"
ARCH="arm64"
ENTITLEMENTS="AstraMusic/AstraMusic.entitlements"
SIDECAR_BIN="$REPO_ROOT/Sidecar/bin/$SIDECAR_NAME"

# Inside the project so the sandboxed build never needs paths it cannot write,
# and so a failed run leaves nothing outside the repo. `build/` and `dist/` are
# gitignored.
BUILD_DIR="$REPO_ROOT/build/release"
DERIVED_DATA="$BUILD_DIR/DerivedData"
STAGE_DIR="$BUILD_DIR/stage"
DIST_DIR="$REPO_ROOT/dist"

skip_sidecar=0
skip_build=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-sidecar) skip_sidecar=1; shift ;;
    --skip-build)   skip_build=1; shift ;;
    -h|--help)      sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

step() { printf '\n== %s\n' "$1"; }

# --- 1. sidecar ---------------------------------------------------------------
# Bundling the sidecar is the whole point of this script: users must not have to
# install Node. The vendored upstream is a pnpm project (only pnpm-lock.yaml
# exists), so `npm ci` is not an option.
if [[ $skip_sidecar -eq 0 ]]; then
  step "Building sidecar ($SIDECAR_TARGET)"
  ( cd Sidecar \
      && pnpm install --frozen-lockfile \
      && pnpm exec pkg . -t "$SIDECAR_TARGET" -C GZip -o "bin/$SIDECAR_NAME" --no-bytecode )
fi

if [[ ! -x "$SIDECAR_BIN" ]]; then
  echo "error: $SIDECAR_BIN is missing; run without --skip-sidecar" >&2
  exit 1
fi

# --- 2. smoke test the sidecar ------------------------------------------------
# The real risk of the pkg step is a dependency that only a dynamic require
# reaches, which the build cannot detect. Probe an unknown path: any HTTP reply
# (including the 404 Express returns) proves the process bound its port, and it
# keeps the check independent of Kugou being reachable.
step "Smoke testing sidecar"
SMOKE_PORT=6599
"$SIDECAR_BIN" --platform=lite --port="$SMOKE_PORT" >/dev/null 2>&1 &
SMOKE_PID=$!
trap 'kill "$SMOKE_PID" 2>/dev/null || true' EXIT
smoke_ok=0
for _ in $(seq 1 20); do
  if curl -s -o /dev/null -m 2 "http://127.0.0.1:$SMOKE_PORT/health"; then
    smoke_ok=1
    break
  fi
  sleep 0.5
done
kill "$SMOKE_PID" 2>/dev/null || true
wait "$SMOKE_PID" 2>/dev/null || true
if [[ $smoke_ok -ne 1 ]]; then
  echo "error: the sidecar never answered on port $SMOKE_PORT" >&2
  exit 1
fi

# --- 3. app -------------------------------------------------------------------
# Signed ad-hoc on purpose; `CODE_SIGNING_ALLOWED=NO` would produce an unsigned
# binary that Apple Silicon refuses to launch, so it must not be used here.
if [[ $skip_build -eq 0 ]]; then
  step "Building $APP_NAME (Release, $ARCH, ad-hoc)"
  rm -rf "$DERIVED_DATA"
  xcodebuild \
    -project AstraMusic.xcodeproj \
    -scheme "$APP_NAME" \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS="$ARCH" ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES \
    build
fi

APP_SRC="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
if [[ ! -d "$APP_SRC" ]]; then
  echo "error: $APP_SRC is missing; run without --skip-build" >&2
  exit 1
fi

# --- 4. stage -----------------------------------------------------------------
# Work on a copy: inserting files invalidates the signature xcodebuild applied,
# so the bundle is re-signed below rather than built to.
step "Staging app"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP_SRC" "$STAGE_DIR/$APP_NAME.app"
APP="$STAGE_DIR/$APP_NAME.app"

# --- 5. embed sidecar + licenses ----------------------------------------------
step "Embedding sidecar and license files"
# Contents/MacOS is where `Bundle.main.url(forAuxiliaryExecutable:)` looks, which
# is how SidecarController finds it.
install -m 755 "$SIDECAR_BIN" "$APP/Contents/MacOS/$SIDECAR_NAME"
mkdir -p "$APP/Contents/Resources/Licenses"
# MIT requires the copyright notice to travel with the binary.
cp Sidecar/LICENSE "$APP/Contents/Resources/Licenses/KuGouMusicApi-LICENSE"
cp NOTICE "$APP/Contents/Resources/Licenses/AstraMusic-NOTICE"

# --- 6. sign ------------------------------------------------------------------
# Inner first, then the bundle, because signing the app seals Contents/MacOS —
# touching the sidecar afterwards would invalidate it. No hardened runtime: that
# would impose library validation on the embedded executable, which ad-hoc
# signing cannot satisfy (and it is only required for notarization).
step "Signing (inner then outer, ad-hoc)"
codesign --force --sign - "$APP/Contents/MacOS/$SIDECAR_NAME"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# --- 7. dmg -------------------------------------------------------------------
step "Creating DMG"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
DMG="$DIST_DIR/$APP_NAME-v$VERSION.dmg"
# The symlink is a sibling of the app, so drag-to-install works and the bundle's
# signature stays intact.
ln -s /Applications "$STAGE_DIR/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG"

step "Done"
echo "$DMG"
du -h "$DMG"
shasum -a 256 "$DMG"
