#!/usr/bin/env bash
# install-local.sh - make a from-source build behave exactly like a Homebrew install.
#
# Mirrors the canonical update-from-HEAD workflow:
#   stop/uninstall old service -> install binary into PATH -> codesign with a STABLE
#   self-signed cert (so macOS Accessibility/Screen-Recording grants survive rebuilds)
#   -> refresh the passwordless `--load-sa` sudoers entry (hash of the SIGNED binary)
#   -> load the scripting addition -> start the launchd service.
#
# Run via `make install-local` (which builds first). Honours:
#   PREFIX      install location (default /opt/homebrew, i.e. $(brew --prefix))
#   YABAI_CERT  code-signing identity   (default yabai-cert)
#
# Requires a `yabai-cert` Code Signing identity in your keychain. Create one once:
#   Keychain Access -> Certificate Assistant -> Create a Certificate
#     Name: yabai-cert   Identity Type: Self Signed Root   Certificate Type: Code Signing
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  cat >&2 <<'EOF'
error: run this as your normal user, NOT with sudo (`make install-local`, not `sudo make ...`).
It elevates only the steps that need root and will prompt for your password.
Running the whole thing as root signs against root's keychain, writes a `root` sudoers
entry, and makes --load-sa look for the wrong per-user SA socket (SUDO_UID=0) -> it fails.
EOF
  exit 1
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-/opt/homebrew}"
YABAI_CERT="${YABAI_CERT:-yabai-cert}"
BIN_SRC="$root/bin/yabai"
BIN_DST="$PREFIX/bin/yabai"
SUDOERS="/private/etc/sudoers.d/yabai"

if [ "${1:-}" = "--uninstall" ]; then
  echo "==> uninstalling"
  yabai --stop-service 2>/dev/null || true
  yabai --uninstall-service 2>/dev/null || true
  sudo "$BIN_DST" --uninstall-sa 2>/dev/null || true
  rm -f "$BIN_DST"
  sudo rm -f "$SUDOERS"
  echo "==> removed binary, service, scripting-addition, and sudoers entry"
  exit 0
fi

[ -x "$BIN_SRC" ] || { echo "error: $BIN_SRC not built — run 'make' first" >&2; exit 1; }

echo "==> stopping any existing service"
yabai --stop-service 2>/dev/null || true
yabai --uninstall-service 2>/dev/null || true

echo "==> installing $BIN_SRC -> $BIN_DST"
mkdir -p "$PREFIX/bin"
rm -f "$BIN_DST"                      # clear any prior symlink (e.g. from a dev `ln -s`)
cp "$BIN_SRC" "$BIN_DST"

echo "==> codesigning with '$YABAI_CERT' (stable identity -> Accessibility persists across rebuilds)"
if ! codesign -fs "$YABAI_CERT" "$BIN_DST" 2>/dev/null; then
  cat >&2 <<EOF
error: code-signing identity '$YABAI_CERT' not found or unusable.
Create a self-signed Code Signing certificate once, then re-run:
  Keychain Access -> Certificate Assistant -> Create a Certificate
    Name: $YABAI_CERT   Identity Type: Self Signed Root   Certificate Type: Code Signing
(or point at another identity with YABAI_CERT=...)
EOF
  rm -f "$BIN_DST"
  exit 1
fi
codesign --verify --verbose "$BIN_DST"

echo "==> refreshing $SUDOERS (passwordless --load-sa, pinned to the SIGNED binary's hash)"
hash="$(shasum -a 256 "$BIN_DST" | cut -d' ' -f1)"
printf '%s ALL=(root) NOPASSWD: sha256:%s %s --load-sa\n' "$(whoami)" "$hash" "$BIN_DST" \
  | sudo tee "$SUDOERS" >/dev/null
sudo chmod 0440 "$SUDOERS"
sudo visudo -cf "$SUDOERS"           # validate; aborts if the entry is malformed

echo "==> loading scripting addition"
sudo "$BIN_DST" --load-sa

echo "==> starting launchd service"
"$BIN_DST" --start-service

cat <<EOF

==> done. yabai is signed ($YABAI_CERT), installed at $BIN_DST, SA loaded, service running.
    First run after a NEW signature: grant Accessibility once
    (System Settings -> Privacy & Security -> Accessibility). It will persist from now on.
EOF
