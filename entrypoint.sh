#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Entrypoint for the Affinity/Wine container.
#
# On first start this materialises the prebuilt Wine prefix into the data
# volume, downloads + unpacks Affinity, and then launches it. Subsequent
# starts skip straight to the launch.
set -euo pipefail

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
AFFINITY_RENDERER="${AFFINITY_RENDERER:-dxvk}"
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

# Restrict Vulkan to the GPU that drives the display.
#
# The launcher passes the DRM driver of whichever card owns a connected output.
# Without this, DXVK picks the discrete card on a hybrid laptop, cannot create a
# Vulkan surface for a display owned by the other GPU, and falls back to copying
# every frame through GDI -- which crashes Affinity within seconds.
#
# Only Vulkan is constrained. OpenCL has its own loader in /etc/OpenCL/vendors,
# so Affinity's hardware acceleration still reaches the NVIDIA card.
setup_vulkan_device() {
    local drv="${AFFINITY_GPU_DRIVER:-}"
    [ -n "$drv" ] || return 0

    local icd=""
    case "$drv" in
        amdgpu|radeon) icd=/usr/share/vulkan/icd.d/radeon_icd.json ;;
        i915|xe)       icd=/usr/share/vulkan/icd.d/intel_icd.json ;;
        nvidia*)       icd=/etc/vulkan/icd.d/nvidia_icd.json ;;
        *)             warn "Unknown DRM driver '$drv'; leaving all Vulkan devices visible."
                       return 0 ;;
    esac

    if [ ! -r "$icd" ]; then
        warn "No Vulkan ICD for '$drv' at $icd -- leaving all devices visible."
        return 0
    fi

    # VK_DRIVER_FILES is the current name; VK_ICD_FILENAMES is kept for older
    # loaders, which ignore the former.
    export VK_DRIVER_FILES="$icd"
    export VK_ICD_FILENAMES="$icd"
    log "Vulkan restricted to $(basename "$icd") ($drv)"
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

# Give the shared host paths their own drive letters.
#
# Everything is reachable under Z: (Wine maps that to /), but Z:\home\you\... is
# an awkward thing to navigate to in a file dialog. A drive letter shows up in
# the sidebar and is one click away.
#
#   H:  your home directory on the host
#   Y:  the whole host filesystem, with AFFINITY_SHARE=all
setup_drives() {
    local dd="$PREFIX/dosdevices"
    [ -d "$dd" ] || return 0

    # '|' as the separator, because a drive spec already contains the colon that
    # Wine requires in the dosdevices name ("h:", not "h").
    local pair letter target
    for pair in "h|${AFFINITY_HOST_HOME:-}" "y|${AFFINITY_HOSTFS:-}"; do
        letter=${pair%%|*}
        target=${pair#*|}
        if [ -z "$target" ] || [ ! -d "$target" ]; then
            # Drop a stale letter if the share was narrowed since last run.
            [ -L "$dd/$letter:" ] && rm -f "$dd/$letter:"
            continue
        fi
        ln -sfn "$target" "$dd/$letter:" 2>/dev/null || true
        log "Drive $letter: -> $target"
    done
}

# Point the Windows user profile at the shared host directories.
#
# The launcher bind-mounts the XDG directories at their real paths, but Affinity's
# file dialogs open "Pictures" and "Documents" from the Windows profile, which
# lives inside the prefix. Replacing those with symlinks is what Wine itself does
# on a normal desktop install, and makes Save As land in the right place.
#
# An existing directory with content in it is left alone -- that is Affinity's
# data, not ours to move.
setup_user_dirs() {
    local profile="$PREFIX/drive_c/users/affinity"
    [ -d "$profile" ] || return 0

    local pair name target
    for pair in "Pictures:${AFFINITY_XDG_PICTURES:-}" \
                "Documents:${AFFINITY_XDG_DOCUMENTS:-}" \
                "Downloads:${AFFINITY_XDG_DOWNLOAD:-}" \
                "Desktop:${AFFINITY_XDG_DESKTOP:-}"; do
        name=${pair%%:*}
        target=${pair#*:}
        [ -n "$target" ] && [ -d "$target" ] || continue

        local link="$profile/$name"
        if [ -L "$link" ]; then
            [ "$(readlink "$link")" = "$target" ] && continue
            rm -f "$link"
        elif [ -d "$link" ]; then
            # Wine seeds these with empty subdirectories of its own (Pictures
            # gets a Screenshots folder, for instance). Prune empty directories
            # so the link can be made, but never touch a file: if anything real
            # is in there it is the user's, and the folder is left alone.
            find "$link" -mindepth 1 -depth -type d -empty -delete 2>/dev/null || true
            rmdir "$link" 2>/dev/null || {
                warn "$name in the Windows profile holds files; leaving it as is."
                warn "Your host $name is still reachable under Z:$target"
                continue
            }
        fi
        ln -sfn "$target" "$link" 2>/dev/null || true
    done
    log "Windows profile folders linked to the shared host directories."
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

# WPF -- which is what Affinity's window chrome and dialogs are built from --
# renders through Direct3D 9, not 11 or 12. That makes DXVK the interesting part
# of the renderer choice: without it, D3D9 falls back to WineD3D over OpenGL, and
# on a hybrid GPU where Mesa cannot drive the discrete card ("libEGL: failed to
# create dri2 screen") the result is white dialogs, chrome painted past the window
# edges, and eventually a hang. Software OpenGL happens to work, which is why the
# symptoms can vanish on a machine with no GPU passthrough at all.
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
            log "Renderer: vkd3d-proton (D3D12) only -- D3D9/11 stay on WineD3D/OpenGL"
            warn "WPF renders via D3D9; without DXVK expect white dialogs and glitches."
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

# Escape hatch for broken GPU rendering of the WPF interface.
#
# WPF checks HKCU\SOFTWARE\Microsoft\Avalon.Graphics\DisableHWAcceleration and
# falls back to its own software rasteriser. Slower and heavier on the CPU, but
# it renders correctly no matter what the driver stack is doing. Affinity's own
# canvas is unaffected -- that does not go through WPF.
setup_wpf() {
    local want="${AFFINITY_WPF_SW:-0}"
    local marker="$PREFIX/.wpfsw"
    [ -f "$marker" ] && [ "$(cat "$marker")" = "$want" ] && return 0

    if [ "$want" = "1" ]; then
        wine reg add 'HKCU\SOFTWARE\Microsoft\Avalon.Graphics' /v DisableHWAcceleration \
            /t REG_DWORD /d 1 /f >/dev/null 2>&1 || true
        log "WPF hardware acceleration disabled (software rendering for the UI)."
    else
        wine reg add 'HKCU\SOFTWARE\Microsoft\Avalon.Graphics' /v DisableHWAcceleration \
            /t REG_DWORD /d 0 /f >/dev/null 2>&1 || true
    fi
    printf '%s' "$want" > "$marker"
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
    setup_vulkan_device
    report_gpu
    init_prefix
    setup_drives
    setup_user_dirs
    setup_renderer
    setup_wpf
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
    shell|bash) shift; init_prefix; exec /bin/bash "$@" ;;
    winecfg)    init_prefix; check_display; exec winecfg ;;
    winetricks) shift; init_prefix; check_display; exec winetricks "$@" ;;
    wine)       shift; init_prefix; exec wine "$@" ;;
    reinstall)  AFFINITY_FORCE_REINSTALL=1; shift || true; launch_affinity "$@" ;;
    *)          exec "$@" ;;
esac
