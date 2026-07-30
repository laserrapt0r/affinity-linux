#!/usr/bin/env bash
# Entrypoint for the Affinity/Wine container.
#
# On first start this materialises the prebuilt Wine prefix into the data
# volume, downloads + unpacks Affinity, and then launches it. Subsequent
# starts skip straight to the launch.
set -euo pipefail

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
AFFINITY_RENDERER="${AFFINITY_RENDERER:-vkd3d}"
AFFINITY_APL="${AFFINITY_APL:-1}"
AFFINITY_MSIX_URL="${AFFINITY_MSIX_URL:-https://downloads.affinity.studio/Affinity%20x64.msix}"

DATA=/data
PREFIX="${WINEPREFIX:-/data/prefix}"
APPDIR="$DATA/affinity"
MSIX_CACHE="$DATA/cache/Affinity-x64.msix"
STAMP="$APPDIR/.installed-version"

log()  { printf '\033[1;34m[affinity]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[affinity]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[affinity]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Drop privileges to PUID/PGID when started as root, so files written into the
# mounted volume belong to the invoking user.
# ---------------------------------------------------------------------------
if [ "$(id -u)" = "0" ]; then
    current_uid=$(id -u affinity 2>/dev/null || echo "")
    current_gid=$(id -g affinity 2>/dev/null || echo "")
    [ -n "$current_gid" ] && [ "$current_gid" != "$PGID" ] && groupmod -o -g "$PGID" affinity
    [ -n "$current_uid" ] && [ "$current_uid" != "$PUID" ] && usermod  -o -u "$PUID" affinity
    mkdir -p "$DATA"
    # Only chown the top level + our own dirs; a full recursive chown over a
    # large prefix costs many seconds on every start.
    chown "$PUID:$PGID" "$DATA"
    exec setpriv --reuid="$PUID" --regid="$PGID" --init-groups \
        env HOME=/data "$0" "$@"
fi

export HOME=/data
export WINEPREFIX="$PREFIX"
export WINEARCH="${WINEARCH:-win64}"
export WINEDEBUG="${WINEDEBUG:--all}"

# ---------------------------------------------------------------------------
# Sanity checks for the GUI / GPU plumbing
# ---------------------------------------------------------------------------
check_display() {
    [ -n "${DISPLAY:-}" ] || die "DISPLAY is not set. Start the container with -e DISPLAY=\$DISPLAY and -v /tmp/.X11-unix:/tmp/.X11-unix:ro"
    if ! xdpyinfo >/dev/null 2>&1; then
        die "Cannot reach X server on DISPLAY=$DISPLAY.
     Check that /tmp/.X11-unix is mounted and that the container is
     authorised (see 'X11 access' in the README)."
    fi
}

report_gpu() {
    if command -v vulkaninfo >/dev/null 2>&1; then
        local names
        names=$(vulkaninfo --summary 2>/dev/null | awk -F= '/deviceName/{gsub(/^ +/,"",$2); print $2}' | paste -sd', ')
        if [ -n "$names" ]; then
            log "Vulkan devices: $names"
            # Warn if the software rasteriser is the only thing available.
            if ! printf '%s' "$names" | tr ',' '\n' | grep -qvi llvmpipe; then
                warn "Only the llvmpipe software rasteriser is visible -- there is no GPU"
                warn "acceleration. Pass --gpus all (NVIDIA) or --device /dev/dri (AMD/Intel)."
            fi
        else
            warn "No Vulkan device found; Affinity will fall back to software rendering."
        fi
    fi
}

# ---------------------------------------------------------------------------
# First-run provisioning
# ---------------------------------------------------------------------------
init_prefix() {
    if [ ! -d "$PREFIX" ]; then
        log "First start: installing Wine prefix into the data volume..."
        cp -a /opt/wine-template "$PREFIX"
    fi
    mkdir -p "$DATA/cache"
}

# Install a set of DLLs into the prefix and mark them as native overrides.
# Copy a translation layer into the prefix and mark exactly those DLLs it
# actually ships as native overrides -- an override pointing at a DLL that is
# not there would make the whole API fail to load.
install_dlls() {
    local src="$1"
    local overrides=""
    # DXVK names its 32-bit directory x32, vkd3d-proton calls it x86.
    [ -d "$src/x64" ] && cp -f "$src/x64/"*.dll "$PREFIX/drive_c/windows/system32/" 2>/dev/null || true
    for d in x32 x86; do
        [ -d "$src/$d" ] && cp -f "$src/$d/"*.dll "$PREFIX/drive_c/windows/syswow64/" 2>/dev/null || true
    done
    for f in "$src"/x64/*.dll; do
        [ -e "$f" ] || continue
        local dll; dll=$(basename "$f" .dll)
        overrides="${overrides:+$overrides,}$dll"
        wine reg add 'HKCU\Software\Wine\DllOverrides' /v "$dll" /d native /f >/dev/null 2>&1 || true
    done
    log "Native DLLs from $(basename "$src"): ${overrides:-none}"
}

setup_renderer() {
    local marker="$PREFIX/.renderer"
    [ -f "$marker" ] && [ "$(cat "$marker")" = "$AFFINITY_RENDERER" ] && return 0

    case "$AFFINITY_RENDERER" in
        dxvk)
            log "Renderer: DXVK (D3D9/10/11) + vkd3d-proton (D3D12)"
            install_dlls /opt/dxvk
            install_dlls /opt/vkd3d
            ;;
        vkd3d)
            log "Renderer: vkd3d-proton (D3D12), WineD3D for D3D11"
            install_dlls /opt/vkd3d
            ;;
        wined3d)
            log "Renderer: WineD3D only (no Vulkan translation)"
            for dll in d3d9 d3d10core d3d11 dxgi d3d12 d3d12core; do
                wine reg delete 'HKCU\Software\Wine\DllOverrides' /v "$dll" /f >/dev/null 2>&1 || true
            done
            ;;
        *)
            die "Unknown AFFINITY_RENDERER='$AFFINITY_RENDERER' (use dxvk, vkd3d or wined3d)"
            ;;
    esac
    wineserver -w
    printf '%s' "$AFFINITY_RENDERER" > "$marker"
}

# Tell Wine what the desktop's DPI is.
#
# Wine reports a fixed 96 DPI to Windows applications unless LogPixels says
# otherwise, so on a HiDPI screen Affinity renders at half or a third of the
# size everything else on the desktop has. This is the same knob winecfg's
# "screen resolution" slider turns. Affinity is WPF and honours the system DPI,
# so setting it scales the whole UI, not just fonts.
#
#   96 = 100%,  120 = 125%,  144 = 150%,  168 = 175%,  192 = 200%
setup_dpi() {
    local dpi="${AFFINITY_DPI:-}"
    [ -n "$dpi" ] || return 0
    case "$dpi" in
        ''|*[!0-9]*) warn "Ignoring non-numeric AFFINITY_DPI='$dpi'"; return 0 ;;
    esac
    # Clamp: a bogus value here produces a window thousands of pixels wide.
    [ "$dpi" -lt 96 ]  && dpi=96
    [ "$dpi" -gt 384 ] && { warn "AFFINITY_DPI=$dpi is implausible; using 96."; dpi=96; }

    local marker="$PREFIX/.dpi"
    [ -f "$marker" ] && [ "$(cat "$marker")" = "$dpi" ] && return 0

    wine reg add 'HKCU\Control Panel\Desktop' /v LogPixels /t REG_DWORD /d "$dpi" /f >/dev/null 2>&1 || true
    wine reg add 'HKCU\Software\Wine\Fonts'   /v LogPixels /t REG_DWORD /d "$dpi" /f >/dev/null 2>&1 || true
    printf '%s' "$dpi" > "$marker"
    log "Display scaling: ${dpi} DPI ($(( dpi * 100 / 96 ))%)"
}

download_msix() {
    # A read-only pre-downloaded copy can be mounted at /msix to skip this.
    if [ -f /msix/Affinity-x64.msix ]; then
        log "Using mounted MSIX at /msix/Affinity-x64.msix"
        MSIX_CACHE=/msix/Affinity-x64.msix
        return 0
    fi
    if [ -f "$MSIX_CACHE" ]; then
        log "Using cached MSIX ($(du -h "$MSIX_CACHE" | cut -f1))"
        return 0
    fi
    log "Downloading Affinity from $AFFINITY_MSIX_URL (~640 MiB)..."
    curl -fL --retry 3 --retry-delay 5 -o "$MSIX_CACHE.part" "$AFFINITY_MSIX_URL" \
        || die "Download failed."
    mv "$MSIX_CACHE.part" "$MSIX_CACHE"
}

install_affinity() {
    local version
    if [ -f "$STAMP" ] && [ -x "$APPDIR/App/Affinity.exe" ] && [ "${AFFINITY_FORCE_REINSTALL:-0}" != "1" ]; then
        log "Affinity $(cat "$STAMP") already installed."
        return 0
    fi

    download_msix

    log "Unpacking MSIX..."
    rm -rf "$APPDIR.new"
    mkdir -p "$APPDIR.new"
    # An MSIX is a plain ZIP; Wine cannot run AppX deployment, so we unpack it
    # ourselves and launch the contained Win32 executable directly.
    unzip -q -o "$MSIX_CACHE" -d "$APPDIR.new" \
        || die "MSIX extraction failed."
    [ -f "$APPDIR.new/App/Affinity.exe" ] || die "App/Affinity.exe not found in the MSIX."

    version=$(grep -ao 'Version="[0-9.]*"' "$APPDIR.new/AppxManifest.xml" | head -1 | \
              sed 's/Version="//; s/"//') || version=unknown
    rm -rf "$APPDIR"
    mv "$APPDIR.new" "$APPDIR"
    printf '%s' "${version:-unknown}" > "$STAMP"
    log "Installed Affinity ${version:-unknown}"
}

# Apply AffinityPluginLoader + WineFix into the app directory.
#
# Without this, Affinity dies with an SEHException in the WPF message loop a
# minute or two after startup because it cannot find a WebView2 runtime to host
# the Canva sign-in dialog -- and WebView2 cannot be installed under Wine.
# WineFix patches that dialog out. Re-applied on every start, since installing
# or updating Affinity replaces the whole directory.
install_apl() {
    if [ "$AFFINITY_APL" != "1" ]; then
        log "APL/WineFix disabled (AFFINITY_APL=0) -- expect a crash when the sign-in dialog opens."
        return 0
    fi
    [ -d /opt/apl ] || { warn "/opt/apl missing; continuing without WineFix."; return 0; }

    cp -rf /opt/apl/. "$APPDIR/App/"
    # The patched d2d1.dll sits next to the executable, so Wine has to be told
    # to prefer a native one over its own builtin.
    wine reg add 'HKCU\Software\Wine\DllOverrides' /v d2d1 /d native,builtin /f >/dev/null 2>&1 || true
    log "APL + WineFix applied."
}

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------
launch_affinity() {
    check_display
    report_gpu
    init_prefix
    setup_renderer
    setup_dpi
    install_affinity
    install_apl

    # Affinity writes its settings below the Windows user profile, which lives
    # inside the prefix and therefore on the volume -- nothing to do here.
    local exe="$APPDIR/App/Affinity.exe"
    if [ "$AFFINITY_APL" = "1" ] && [ -f "$APPDIR/App/AffinityHook.exe" ]; then
        exe="$APPDIR/App/AffinityHook.exe"
    fi

    log "Starting Affinity ($(basename "$exe"))..."
    cd "$APPDIR/App"
    exec wine "$exe" "$@"
}

case "${1:-affinity}" in
    affinity)   shift || true; launch_affinity "$@" ;;
    shell|bash) init_prefix; exec /bin/bash ;;
    winecfg)    init_prefix; check_display; exec winecfg ;;
    winetricks) shift; init_prefix; check_display; exec winetricks "$@" ;;
    wine)       shift; init_prefix; exec wine "$@" ;;
    reinstall)  AFFINITY_FORCE_REINSTALL=1; shift || true; launch_affinity "$@" ;;
    *)          exec "$@" ;;
esac
