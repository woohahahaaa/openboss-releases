#!/bin/sh
# OpenBoss installer for macOS / Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/woohahahaaa/openboss-releases/main/install.sh | sh
#
# 安装脚本做这些事：下载最新发行版、校验 SHA256、装到固定目录并链接到
# PATH、注册登录自启（launchd / systemd --user）；macOS 还会在桌面生成
# OpenBoss.app 启动器（双击用 Chrome --app 模式打开控制台）。重复执行即为升级。
#
# 环境变量：
#   OPENBOSS_HOME          安装根目录（默认 ~/.openboss）
#   OPENBOSS_BIN_DIR       命令链接目录（默认 ~/.local/bin）
#   OPENBOSS_NO_SERVICE=1  跳过自启服务注册
#   OPENBOSS_NO_DESKTOP=1  macOS：跳过桌面启动器生成
set -eu

BASE="https://github.com/woohahahaaa/openboss-releases/releases/latest/download"
APP_DIR="${OPENBOSS_HOME:-$HOME/.openboss}/app"
BIN_DIR="${OPENBOSS_BIN_DIR:-$HOME/.local/bin}"

say() { printf '[openboss] %s\n' "$*"; }
die() { printf '[openboss] %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl not found"

case "$(uname -s)" in
  Darwin) os=darwin ;;
  Linux)  os=linux ;;
  *) die "unsupported OS: $(uname -s) — on Windows use install.ps1" ;;
esac
case "$(uname -m)" in
  arm64|aarch64) arch=arm64 ;;
  x86_64|amd64)  arch=amd64 ;;
  *) die "unsupported arch: $(uname -m)" ;;
esac
case "$os-$arch" in
  darwin-arm64|darwin-amd64) asset="openboss-darwin-universal.tar.gz" ;;
  linux-amd64) asset="openboss-linux-amd64.tar.gz" ;;
  linux-arm64) asset="openboss-linux-arm64.tar.gz" ;;
  *) die "no OpenBoss build for $os-$arch" ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say "downloading $asset ..."
curl -fsSL -o "$WORK/$asset" "$BASE/$asset" || die "download failed"
curl -fsSL -o "$WORK/SHA256SUMS" "$BASE/SHA256SUMS" || die "checksum manifest download failed"

say "verifying checksum ..."
expect="$(awk -v n="$asset" 'NF==2 && $2==n {print $1}' "$WORK/SHA256SUMS")"
[ -n "$expect" ] || die "$asset is not listed in SHA256SUMS"
if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "$WORK/$asset" | awk '{print $1}')"
else
  actual="$(shasum -a 256 "$WORK/$asset" | awk '{print $1}')"
fi
[ "$actual" = "$expect" ] || die "checksum mismatch (got $actual)"

say "installing to $APP_DIR ..."
mkdir -p "$WORK/extract"
tar -xzf "$WORK/$asset" -C "$WORK/extract"
[ -f "$WORK/extract/openboss" ] || die "archive is missing the openboss binary"
mkdir -p "$APP_DIR"
cp "$WORK/extract/openboss" "$APP_DIR/openboss.new"
chmod +x "$APP_DIR/openboss.new"
mv -f "$APP_DIR/openboss.new" "$APP_DIR/openboss"
if [ -d "$WORK/extract/EYE" ]; then
  rm -rf "$APP_DIR/EYE.new" "$APP_DIR/EYE.old"
  cp -R "$WORK/extract/EYE" "$APP_DIR/EYE.new"
  if [ -d "$APP_DIR/EYE" ]; then
    mv "$APP_DIR/EYE" "$APP_DIR/EYE.old"
  fi
  mv "$APP_DIR/EYE.new" "$APP_DIR/EYE"
  rm -rf "$APP_DIR/EYE.old"
fi

mkdir -p "$BIN_DIR"
ln -sf "$APP_DIR/openboss" "$BIN_DIR/openboss"
say "linked $BIN_DIR/openboss"

# PATH: 只在用户的第一个 shell 配置里加一次（带标记，不重复写）。
if ! printf '%s' ":${PATH:-}:" | grep -q ":$BIN_DIR:"; then
  rc="$HOME/.zshrc"
  case "${SHELL:-}" in
    *bash*) rc="$HOME/.bashrc" ;;
    "") rc="$HOME/.profile" ;;
  esac
  if ! grep -qs 'openboss PATH' "$rc" 2>/dev/null; then
    printf '\n# openboss PATH\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >> "$rc"
    say "added $BIN_DIR to PATH in $rc (open a new terminal to use it)"
  fi
fi

if [ "${OPENBOSS_NO_SERVICE:-0}" != "1" ]; then
  say "registering autostart service ..."
  "$APP_DIR/openboss" service install || true
  # 以退出码为准判断自启到底装上没有，别只看 install 的返回值：macOS 在无
  # GUI 会话（如 SSH）里 bootstrap 会失败，但单元已经写好，下次登录 launchd
  # 仍会自动加载——那是 4（已安装、当前暂停），仍算成功。
  #   0 = 已安装且正在运行   4 = 已安装但当前暂停   3 = 未安装
  svc_rc=0
  "$APP_DIR/openboss" service status >/dev/null 2>&1 || svc_rc=$?
  case "$svc_rc" in
    0)
      say "autostart ready — backend starts automatically after login"
      ;;
    4)
      say "autostart registered — unit is in place, starts at next login"
      say "start it now with: $APP_DIR/openboss service start"
      ;;
    *)
      say "ERROR: autostart was NOT registered (service status exit $svc_rc)." >&2
      say "       fix the error above, then run: $APP_DIR/openboss service install" >&2
      exit 1
      ;;
  esac
fi

# macOS：桌面生成一个启动器 .app，双击用 Chrome 的 --app 模式打开控制台
# （独立窗口、无地址栏）。这不是真 PWA——真正的 PWA 安装只能由浏览器完成
# （地址栏「安装」/菜单「安装 OpenBoss」），脚本无法代劳。
if [ "$os" = darwin ] && [ "${OPENBOSS_NO_DESKTOP:-0}" != "1" ]; then
  say "creating desktop launcher ..."
  APP="$HOME/Desktop/OpenBoss.app"
  BUILD="$WORK/OpenBoss.app"
  mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources"

  cat > "$BUILD/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OpenBoss</string>
  <key>CFBundleDisplayName</key><string>OpenBoss</string>
  <key>CFBundleIdentifier</key><string>dev.openboss.launcher</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>OpenBoss</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>LSMinimumSystemVersion</key><string>10.13</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

  cat > "$BUILD/Contents/MacOS/OpenBoss" <<'LAUNCHER'
#!/bin/sh
# OpenBoss 启动器：用 Chrome 的 --app 模式打开控制台（独立窗口，无地址栏）。
# 端口从 ~/.openboss/port 读取，读不到退回 18799。
set -u

PORT="$(cat "$HOME/.openboss/port" 2>/dev/null || true)"
case "$PORT" in
  ''|*[!0-9]*) PORT=18799 ;;
esac
URL="http://127.0.0.1:$PORT"

for app in "Google Chrome" "Google Chrome Canary" "Microsoft Edge" "Brave Browser" "Chromium"; do
  bin="/Applications/$app.app/Contents/MacOS/$app"
  if [ -x "$bin" ]; then
    exec "$bin" --app="$URL"
  fi
done

# 没装 Chromium 系浏览器就交给默认浏览器打开
exec open "$URL"
LAUNCHER
  chmod +x "$BUILD/Contents/MacOS/OpenBoss"

  # 图标从本机后端取（web 资源编译在二进制里，本地服务是唯一现成的来源；
  # 服务没跑就退化成默认图标，不算失败）。
  rm -f "$BUILD/Contents/Resources/icon.icns"
  PORT_NOW="$(cat "$HOME/.openboss/port" 2>/dev/null || true)"
  case "$PORT_NOW" in ''|*[!0-9]*) PORT_NOW=18799 ;; esac
  if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1 \
     && curl -fsSL -o "$WORK/icon-512.png" "http://127.0.0.1:$PORT_NOW/icon-512.png"; then
    mkdir -p "$WORK/icon.iconset"
    for s in 16 32 128 256 512; do
      sips -z "$s" "$s" "$WORK/icon-512.png" --out "$WORK/icon.iconset/icon_${s}x${s}.png" >/dev/null 2>&1 || true
      sips -z "$((s * 2))" "$((s * 2))" "$WORK/icon-512.png" --out "$WORK/icon.iconset/icon_${s}x${s}@2x.png" >/dev/null 2>&1 || true
    done
    iconutil -c icns "$WORK/icon.iconset" -o "$BUILD/Contents/Resources/icon.icns" >/dev/null 2>&1 || true
  fi

  rm -rf "$APP"
  mv "$BUILD" "$APP"
  # 让 Finder / LaunchServices 立刻认识这个包（失败无妨，稍后自会刷新）。
  lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  if [ -x "$lsregister" ]; then
    "$lsregister" -f "$APP" >/dev/null 2>&1 || true
  fi
  say "desktop launcher: $APP (double-click to open the console)"
fi

say "done: openboss $("$APP_DIR/openboss" version)"
say "web console: http://127.0.0.1:18799"
