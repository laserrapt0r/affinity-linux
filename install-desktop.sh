#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Desktop integration: menu entry, icons and file associations.
#
# Installs into ~/.local/share, so no root is needed and nothing outside your
# home directory is touched. Works with GNOME, KDE Plasma, XFCE and anything
# else following the freedesktop.org specs.
#
#   ./install-desktop.sh              # install
#   ./install-desktop.sh --uninstall  # remove again
#
# Icons are taken from your own Affinity download (the MSIX ships PNGs in every
# size the icon theme wants), so nothing proprietary lives in this repository.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER="$SCRIPT_DIR/run-affinity.sh"
VOLUME="${AFFINITY_VOLUME:-affinity-data}"
IMAGE="${AFFINITY_IMAGE:-affinity-wine:latest}"

APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICONS="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
MIME="${XDG_DATA_HOME:-$HOME/.local/share}/mime"

DESKTOP_FILE="$APPS/affinity.desktop"
MIME_FILE="$MIME/packages/affinity.xml"

ICON_SIZES="16 24 32 48 64 128 256"

msg()  { printf '\033[1;34m[desktop]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[desktop]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[desktop]\033[0m %s\n' "$*" >&2; exit 1; }

ENGINE="${AFFINITY_ENGINE:-}"
[ -n "$ENGINE" ] || { command -v podman >/dev/null 2>&1 && ENGINE=podman || ENGINE=docker; }

refresh_caches() {
    command -v update-desktop-database >/dev/null 2>&1 && \
        update-desktop-database "$APPS" 2>/dev/null || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 && \
        gtk-update-icon-cache -f -t "$ICONS" 2>/dev/null || true
    command -v update-mime-database >/dev/null 2>&1 && \
        update-mime-database "$MIME" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--uninstall" ]; then
    rm -f "$DESKTOP_FILE" "$MIME_FILE"
    for s in $ICON_SIZES; do rm -f "$ICONS/${s}x${s}/apps/affinity.png"; done
    refresh_caches
    msg "Removed."
    exit 0
fi

[ -x "$LAUNCHER" ] || die "run-affinity.sh not found or not executable at $LAUNCHER"

# ---------------------------------------------------------------------------
# Icons
#
# Preferred source is the unpacked application in the data volume; if Affinity
# has not been started yet, fall back to a downloaded MSIX in cache/.
# ---------------------------------------------------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

extract_from_volume() {
    "$ENGINE" volume inspect "$VOLUME" >/dev/null 2>&1 || return 1
    local opts=(--rm -v "$VOLUME:/data:ro" --entrypoint /bin/sh)
    [ "$ENGINE" = podman ] && opts+=(--userns=keep-id --user "$(id -u):$(id -g)")
    "$ENGINE" run "${opts[@]}" "$IMAGE" -c \
        'cd /data/affinity/Package 2>/dev/null && tar cf - AppLogo.targetsize-*.png 2>/dev/null' \
        2>/dev/null | tar xf - -C "$TMP" 2>/dev/null || return 1
    ls "$TMP"/AppLogo.targetsize-*.png >/dev/null 2>&1
}

extract_from_msix() {
    local msix
    msix=$(ls "$SCRIPT_DIR"/cache/*.msix 2>/dev/null | head -1) || return 1
    [ -n "$msix" ] || return 1
    unzip -q -j -o "$msix" 'Package/AppLogo.targetsize-*.png' -d "$TMP" 2>/dev/null || return 1
    ls "$TMP"/AppLogo.targetsize-*.png >/dev/null 2>&1
}

ICON_OK=0
if extract_from_volume; then
    msg "Icons taken from the $VOLUME volume."
    ICON_OK=1
elif extract_from_msix; then
    msg "Icons taken from the MSIX in cache/."
    ICON_OK=1
else
    warn "Could not find any icons -- start Affinity once, then re-run this script."
    warn "Installing the menu entry with a generic icon for now."
fi

if [ "$ICON_OK" = 1 ]; then
    for s in $ICON_SIZES; do
        # Prefer the unplated variant: no baked-in background tile.
        src=""
        for cand in "$TMP/AppLogo.targetsize-${s}_altform-unplated.png" \
                    "$TMP/AppLogo.targetsize-${s}.png"; do
            [ -f "$cand" ] && { src="$cand"; break; }
        done
        [ -n "$src" ] || continue
        mkdir -p "$ICONS/${s}x${s}/apps"
        cp -f "$src" "$ICONS/${s}x${s}/apps/affinity.png"
    done
    msg "Installed icons: $(ls "$ICONS"/*/apps/affinity.png 2>/dev/null | wc -l) sizes."
fi

# ---------------------------------------------------------------------------
# MIME types for Affinity's own document formats
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$MIME_FILE")"
cat > "$MIME_FILE" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-affinity-document">
    <comment>Affinity document</comment>
    <glob pattern="*.af"/>
    <icon name="affinity"/>
  </mime-type>
  <mime-type type="application/x-affinity-design">
    <comment>Affinity Designer document</comment>
    <glob pattern="*.afdesign"/>
    <icon name="affinity"/>
  </mime-type>
  <mime-type type="application/x-affinity-photo">
    <comment>Affinity Photo document</comment>
    <glob pattern="*.afphoto"/>
    <icon name="affinity"/>
  </mime-type>
  <mime-type type="application/x-affinity-publisher">
    <comment>Affinity Publisher document</comment>
    <glob pattern="*.afpub"/>
    <icon name="affinity"/>
  </mime-type>
  <mime-type type="application/x-affinity-template">
    <comment>Affinity template</comment>
    <glob pattern="*.aftemplate"/>
    <icon name="affinity"/>
  </mime-type>
  <mime-type type="application/x-affinity-package">
    <comment>Affinity package</comment>
    <glob pattern="*.afpackage"/>
    <icon name="affinity"/>
  </mime-type>
</mime-info>
EOF

MIMETYPES="application/x-affinity-document;application/x-affinity-design;application/x-affinity-photo;application/x-affinity-publisher;application/x-affinity-template;application/x-affinity-package;"

# ---------------------------------------------------------------------------
# Desktop entry
#
# StartupWMClass must match the window's WM_CLASS ("affinity.exe" -- Wine names
# it after the executable), otherwise the running window shows up as a second,
# iconless entry in the dock or task bar instead of grouping under this one.
# ---------------------------------------------------------------------------
mkdir -p "$APPS"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Affinity
GenericName=Graphic Design
Comment=Photo editing, vector design and publishing (containerised, via Wine)
Exec=$LAUNCHER %f
TryExec=$LAUNCHER
Icon=affinity
Terminal=false
StartupNotify=true
StartupWMClass=affinity.exe
Categories=Graphics;2DGraphics;RasterGraphics;VectorGraphics;Publishing;
Keywords=Photo;Image;Vector;Design;Publisher;Designer;Canva;
MimeType=$MIMETYPES
Actions=WineCfg;Reinstall;

[Desktop Action WineCfg]
Name=Wine configuration
Exec=$LAUNCHER winecfg
Icon=affinity

[Desktop Action Reinstall]
Name=Reinstall / update Affinity
Exec=$LAUNCHER reinstall
Icon=affinity
EOF

chmod 644 "$DESKTOP_FILE"
refresh_caches

# Make Affinity the default handler for its own formats.
if command -v xdg-mime >/dev/null 2>&1; then
    IFS=';' read -ra types <<< "$MIMETYPES"
    for t in "${types[@]}"; do
        [ -n "$t" ] && xdg-mime default affinity.desktop "$t" 2>/dev/null || true
    done
fi

msg "Installed $DESKTOP_FILE"
msg "Affinity should now appear in your application menu."
msg "Some desktops need a re-login (or 'killall -HUP gnome-shell' on X11) to pick up new icons."
