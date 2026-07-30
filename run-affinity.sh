#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Convenience launcher for the Affinity container.
#
# Handles the fiddly parts: X11 authorisation, GPU passthrough (NVIDIA via CDI,
# AMD/Intel via /dev/dri) and user-id mapping, for both Podman and Docker.
#
#   ./run-affinity.sh              # start Affinity
#   ./run-affinity.sh shell        # a shell inside the container
#   ./run-affinity.sh winecfg      # Wine configuration GUI
#   ./run-affinity.sh reinstall    # re-download and re-unpack Affinity
set -euo pipefail

IMAGE="${AFFINITY_IMAGE:-affinity-wine:latest}"
VOLUME="${AFFINITY_VOLUME:-affinity-data}"
NAME="${AFFINITY_NAME:-affinity}"

# Extra host directories to expose, e.g.
#   AFFINITY_MOUNTS="$HOME/Bilder:/data/Bilder" ./run-affinity.sh
EXTRA_MOUNTS="${AFFINITY_MOUNTS:-}"

# Where to keep the output of the last run. Launched from a .desktop entry there
# is no terminal, so without this any crash diagnostics are simply lost. Set
# AFFINITY_LOG= (empty) to disable, or to a path of your choice.
AFFINITY_LOG="${AFFINITY_LOG-${XDG_STATE_HOME:-$HOME/.local/state}/affinity/last-run.log}"

msg()  { printf '\033[1;34m[run]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[run]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[run]\033[0m %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# Container engine
# --------------------------------------------------------------------------
if [ -n "${AFFINITY_ENGINE:-}" ]; then
    ENGINE="$AFFINITY_ENGINE"
elif command -v podman >/dev/null 2>&1; then
    ENGINE=podman
elif command -v docker >/dev/null 2>&1; then
    ENGINE=docker
else
    die "Neither podman nor docker found."
fi
msg "Engine: $ENGINE"

ARGS=(run --rm --name "$NAME")
# Only ask for a TTY when there actually is one, so the script also works when
# launched from a .desktop file or in the background.
[ -t 0 ] && [ -t 1 ] && ARGS+=(-it)

# --------------------------------------------------------------------------
# X11
# --------------------------------------------------------------------------
[ -n "${DISPLAY:-}" ] || die "DISPLAY is not set -- are you on a graphical session?"

XAUTH_FILE=$(mktemp /tmp/affinity-xauth.XXXXXX)
trap 'rm -f "$XAUTH_FILE"' EXIT
# Re-stamp the cookie as FamilyWild (ffff) so it is accepted regardless of the
# container's hostname. Safer than 'xhost +'.
if command -v xauth >/dev/null 2>&1; then
    xauth nlist "$DISPLAY" 2>/dev/null | sed -e 's/^..../ffff/' | \
        xauth -f "$XAUTH_FILE" nmerge - 2>/dev/null || true
fi
chmod 644 "$XAUTH_FILE"

ARGS+=(-e "DISPLAY=$DISPLAY"
       -v /tmp/.X11-unix:/tmp/.X11-unix:ro
       -v "$XAUTH_FILE:/tmp/.Xauthority:ro"
       -e "XAUTHORITY=/tmp/.Xauthority")

# --------------------------------------------------------------------------
# HiDPI
#
# Wine hands applications a fixed 96 DPI unless told otherwise, so on a scaled
# desktop Affinity comes up tiny. Work out what the desktop actually uses and
# pass it in; the entrypoint writes it to the prefix.
# --------------------------------------------------------------------------
# gsettings prints its type, e.g. "uint32 0" -- strip it before reading the
# number, or the 32 in the type name gets picked up as the scale factor and the
# window ends up 32x too large.
gsetting_num() {
    gsettings get "$1" "$2" 2>/dev/null \
        | sed 's/^uint32[[:space:]]*//; s/^int32[[:space:]]*//' \
        | tr -d "'" \
        | grep -oE '^[0-9]+(\.[0-9]+)?' | head -1
}

detect_dpi() {
    local v

    # Xft.dpi is what GNOME, KDE and most DEs set for HiDPI. 192 = 200%.
    v=$(xrdb -query 2>/dev/null | awk -F: '/^Xft\.dpi/ {gsub(/[ \t]/, "", $2); print $2; exit}')
    if [ -n "$v" ] && [ "$v" -ge 96 ] 2>/dev/null; then echo "$v"; return; fi

    # GNOME integer scale factor (0 means "let the DE decide").
    v=$(gsetting_num org.gnome.desktop.interface scaling-factor)
    if [ -n "$v" ] && [ "${v%%.*}" -ge 1 ] 2>/dev/null; then echo $(( 96 * ${v%%.*} )); return; fi

    # Fractional text scaling, e.g. 1.25 -> 120.
    v=$(gsetting_num org.gnome.desktop.interface text-scaling-factor)
    if [ -n "$v" ]; then
        v=$(awk -v s="$v" 'BEGIN { printf "%d", 96 * s }' 2>/dev/null)
        [ -n "$v" ] && [ "$v" -gt 96 ] 2>/dev/null && { echo "$v"; return; }
    fi

    # KDE Plasma. On X11 Plasma sets Xft.dpi and we never get here, but on
    # Wayland it often does not, so read what Plasma itself recorded.
    local kg="${XDG_CONFIG_HOME:-$HOME/.config}/kdeglobals"
    if [ -r "$kg" ]; then
        v=$(awk -F= '/^[[:space:]]*forceFontDPI[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$kg")
        if [ -n "$v" ] && [ "$v" -ge 96 ] 2>/dev/null; then echo "$v"; return; fi

        # ScaleFactor is a multiplier, e.g. 2 or 1.5.
        v=$(awk -F= '/^[[:space:]]*ScaleFactor[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$kg")
        if [ -n "$v" ]; then
            v=$(awk -v s="$v" 'BEGIN { printf "%d", 96 * s }' 2>/dev/null)
            [ -n "$v" ] && [ "$v" -gt 96 ] 2>/dev/null && { echo "$v"; return; }
        fi
    fi

    echo 96
}

DPI="${AFFINITY_DPI:-$(detect_dpi)}"

# Guard against a bad reading: anything outside this range is a detection bug,
# not a real display, and Wine would build an unusably huge or tiny window.
case "$DPI" in
    ''|*[!0-9]*) warn "Ignoring unusable DPI '$DPI'"; DPI=96 ;;
esac
if [ "$DPI" -lt 96 ] || [ "$DPI" -gt 384 ]; then
    warn "Detected DPI $DPI is out of range (96-384); falling back to 96."
    warn "Set AFFINITY_DPI explicitly if your display really needs it."
    DPI=96
fi
if [ "$DPI" != "96" ]; then
    msg "Display scaling: ${DPI} DPI ($(( DPI * 100 / 96 ))%)"
fi
ARGS+=(-e "AFFINITY_DPI=$DPI")

# Wine draws its own cursors; without this they stay 96-DPI sized.
[ -n "${XCURSOR_SIZE:-}" ] && ARGS+=(-e "XCURSOR_SIZE=$XCURSOR_SIZE")

# X11's MIT-SHM extension moves images through SysV shared memory segments, and
# those are scoped to the IPC namespace. In a container with its own IPC
# namespace the X server cannot attach to them, and Affinity dies the moment it
# paints a canvas:
#   X Error of failed request: BadValue
#   Major opcode: 130 (MIT-SHM), Minor opcode: 3 (X_ShmPutImage)
# --shm-size does not help -- that is POSIX /dev/shm, a different mechanism.
# Sharing the host IPC namespace is what makes MIT-SHM work.
#
# This is the one place where isolation is deliberately relaxed. Set
# AFFINITY_IPC=private to keep the namespace separate; expect the crash above.
# Note: --shm-size may not be combined with --ipc=host; with a shared IPC
# namespace /dev/shm comes from the host anyway.
case "${AFFINITY_IPC:-host}" in
    host)    ARGS+=(--ipc=host) ;;
    private) ARGS+=(--shm-size=2g)
             warn "IPC namespace kept private -- MIT-SHM will fail." ;;
    *)       ARGS+=(--ipc="${AFFINITY_IPC}" --shm-size=2g) ;;
esac

# --------------------------------------------------------------------------
# GPU
# --------------------------------------------------------------------------
GPU_FOUND=0
CDI_SPEC=""

# NVIDIA: prefer CDI (works rootless), fall back to Docker's --gpus.
for cand in /etc/cdi/nvidia.yaml /var/run/cdi/nvidia.yaml; do
    [ -e "$cand" ] && { CDI_SPEC="$cand"; break; }
done

if [ -n "$CDI_SPEC" ]; then
    if [ "$ENGINE" = podman ]; then
        ARGS+=(--device nvidia.com/gpu=all)
    else
        ARGS+=(--gpus all)
    fi
    msg "NVIDIA GPU enabled (CDI)"
    GPU_FOUND=1
elif [ "$ENGINE" = docker ] && command -v nvidia-container-runtime >/dev/null 2>&1; then
    ARGS+=(--gpus all)
    msg "NVIDIA GPU enabled (--gpus all)"
    GPU_FOUND=1
fi

# AMD / Intel: pass the remaining DRI render nodes through.
#
# The CDI spec already injects the NVIDIA card's own nodes. Passing one of those
# a second time makes runc fail with a misleading
#   "create device inode ...: permission denied"
# so anything CDI covers has to be skipped here.
if [ -d /dev/dri ]; then
    CDI_NODES=""
    [ -n "$CDI_SPEC" ] && CDI_NODES=$(grep -oE '/dev/dri/(card|renderD)[0-9]+' "$CDI_SPEC" | sort -u)
    dri_added=0
    for dev in /dev/dri/renderD* /dev/dri/card*; do
        [ -e "$dev" ] || continue
        printf '%s\n' "$CDI_NODES" | grep -qx "$dev" && continue   # already via CDI
        [ -r "$dev" ] || continue                                  # no permission
        ARGS+=(--device "$dev:$dev")
        dri_added=1
    done
    if [ "$dri_added" = 1 ]; then
        msg "Additional DRI nodes enabled (AMD/Intel)"
        GPU_FOUND=1
    fi
fi

[ "$GPU_FOUND" = 1 ] || warn "No GPU passthrough configured -- expect software rendering."

# --------------------------------------------------------------------------
# Which GPU should render?
#
# On a hybrid laptop this matters more than it looks. DXVK picks the "best"
# Vulkan device, which is the discrete NVIDIA card -- but the panel hangs off the
# integrated GPU. Presenting across GPUs cannot use a Vulkan surface, so DXVK
# falls back to copying every frame through GDI:
#
#   warn: Using GDI for swapchain presentation. This will impact performance.
#
# which is slow and, in practice, crashes Affinity within seconds. Rendering on
# whichever GPU actually owns the display avoids the copy entirely.
#
# This only constrains Vulkan. OpenCL uses a separate loader, so Affinity's
# hardware acceleration keeps using the NVIDIA card either way.
#
# Override with AFFINITY_GPU=nvidia|amd|intel|all.
# --------------------------------------------------------------------------
detect_display_driver() {
    local st card drv
    for st in /sys/class/drm/card*-*/status; do
        [ -r "$st" ] || continue
        [ "$(cat "$st" 2>/dev/null)" = "connected" ] || continue
        card=$(basename "$(dirname "$st")"); card=${card%%-*}
        drv=$(basename "$(readlink -f "/sys/class/drm/$card/device/driver" 2>/dev/null)" 2>/dev/null)
        [ -n "$drv" ] && { echo "$drv"; return; }
    done
}

case "${AFFINITY_GPU:-auto}" in
    nvidia) GPU_DRIVER=nvidia ;;
    amd)    GPU_DRIVER=amdgpu ;;
    intel)  GPU_DRIVER=i915 ;;
    all)    GPU_DRIVER="" ;;
    auto)   GPU_DRIVER=$(detect_display_driver) ;;
    *)      die "AFFINITY_GPU must be nvidia, amd, intel, all or auto." ;;
esac

if [ -n "${GPU_DRIVER:-}" ]; then
    msg "Rendering GPU: $GPU_DRIVER (drives the display)"
    ARGS+=(-e "AFFINITY_GPU_DRIVER=$GPU_DRIVER")
    if [ "$GPU_DRIVER" = nvidia ]; then
        ARGS+=(-e "__NV_PRIME_RENDER_OFFLOAD=1" -e "__GLX_VENDOR_LIBRARY_NAME=nvidia")
    fi
fi

[ -n "${AFFINITY_RENDERER:-}" ] && ARGS+=(-e "AFFINITY_RENDERER=$AFFINITY_RENDERER")
[ -n "${AFFINITY_WPF_SW:-}" ] && ARGS+=(-e "AFFINITY_WPF_SW=$AFFINITY_WPF_SW")
[ -n "${WINEDEBUG:-}" ] && ARGS+=(-e "WINEDEBUG=$WINEDEBUG")

# --------------------------------------------------------------------------
# Storage and user mapping
# --------------------------------------------------------------------------
ARGS+=(-v "$VOLUME:/data")

# Reuse an already-downloaded MSIX if there is one next to this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/cache/Affinity-x64.msix" ]; then
    ARGS+=(-v "$SCRIPT_DIR/cache:/msix:ro")
    msg "Reusing local MSIX from cache/"
fi

# --------------------------------------------------------------------------
# Host files
#
# A container sees none of your files unless you say so, and an image editor
# that cannot open or save anything is not much use. The default is a middle
# ground: the XDG user directories where pictures and documents actually live,
# mounted at their real paths, and nothing else -- so ~/.ssh, browser profiles
# and the rest of your home directory stay outside.
#
# AFFINITY_SHARE=xdg   Pictures, Documents, Downloads, Desktop (default)
#                home  all of $HOME -- convenient, much weaker isolation
#                none  nothing; use AFFINITY_MOUNTS for specific paths
# --------------------------------------------------------------------------
MOUNTED_DIRS=""

add_dir_mount() {
    local dir="$1" mode="${2:-rw}"
    [ -n "$dir" ] && [ -d "$dir" ] || return 0
    case ":$MOUNTED_DIRS:" in *":$dir:"*) return 0 ;; esac
    if [ "$mode" = ro ]; then ARGS+=(-v "$dir:$dir:ro"); else ARGS+=(-v "$dir:$dir"); fi
    MOUNTED_DIRS="$MOUNTED_DIRS:$dir"
}

# Resolve an XDG directory without depending on xdg-user-dir being installed.
xdg_dir() {
    local key="$1" fallback="$2" v=""
    if command -v xdg-user-dir >/dev/null 2>&1; then
        v=$(xdg-user-dir "$key" 2>/dev/null)
    fi
    if [ -z "$v" ] || [ "$v" = "$HOME" ]; then
        v=$(awk -F= -v k="XDG_${key}_DIR" '$1==k {gsub(/"/,"",$2); print $2; exit}' \
              "${XDG_CONFIG_HOME:-$HOME/.config}/user-dirs.dirs" 2>/dev/null)
        v=$(eval echo "$v" 2>/dev/null)
    fi
    [ -z "$v" ] || [ "$v" = "$HOME" ] && v="$HOME/$fallback"
    echo "$v"
}

case "${AFFINITY_SHARE:-xdg}" in
    none) ;;
    home)
        add_dir_mount "$HOME"
        ARGS+=(-e "AFFINITY_XDG_PICTURES=$(xdg_dir PICTURES Pictures)"
               -e "AFFINITY_XDG_DOCUMENTS=$(xdg_dir DOCUMENTS Documents)"
               -e "AFFINITY_XDG_DOWNLOAD=$(xdg_dir DOWNLOAD Downloads)"
               -e "AFFINITY_XDG_DESKTOP=$(xdg_dir DESKTOP Desktop)")
        msg "Sharing all of $HOME"
        ;;
    xdg)
        shared=""
        for key_fallback in "PICTURES:Pictures" "DOCUMENTS:Documents" \
                            "DOWNLOAD:Downloads" "DESKTOP:Desktop"; do
            key=${key_fallback%%:*}; fb=${key_fallback##*:}
            d=$(xdg_dir "$key" "$fb")
            if [ -d "$d" ]; then
                add_dir_mount "$d"
                ARGS+=(-e "AFFINITY_XDG_${key}=$d")
                shared="${shared:+$shared, }$(basename "$d")"
            fi
        done
        [ -n "$shared" ] && msg "Sharing: $shared" \
                         || warn "No XDG user directories found -- Affinity will see no host files."
        ;;
    *)  die "AFFINITY_SHARE must be xdg, home or none." ;;
esac

for m in $EXTRA_MOUNTS; do
    ARGS+=(-v "$m")
done

if [ "$ENGINE" = podman ]; then
    # keep-id maps the host user 1:1 into the container, so files written to
    # bind mounts stay owned by us.
    ARGS+=(--userns=keep-id --user "$(id -u):$(id -g)")
else
    ARGS+=(-e "PUID=$(id -u)" -e "PGID=$(id -g)")
fi

# --------------------------------------------------------------------------
# Arguments
#
# The desktop entry passes file paths (%f), so a double-clicked document has to
# reach the container: bind-mount its directory at the identical path, then hand
# Affinity the Wine equivalent. Wine maps Z: to /, so /home/you/x.afdesign
# becomes Z:\home\you\x.afdesign.
#
# Subcommands (shell, winecfg, reinstall, ...) are passed through untouched.
# --------------------------------------------------------------------------
CMD=()
FILES=()

for arg in "$@"; do
    case "$arg" in
        affinity|shell|bash|winecfg|winetricks|wine|reinstall)
            CMD+=("$arg"); continue ;;
    esac
    if [ -e "$arg" ]; then
        abs=$(readlink -f "$arg")
        add_dir_mount "$(dirname "$abs")"
        FILES+=("Z:${abs//\//\\}")
    else
        CMD+=("$arg")
    fi
done

# Files are arguments to Affinity, so the entrypoint needs its 'affinity' verb
# in front of them -- otherwise it would try to execute the path as a command.
if [ ${#FILES[@]} -gt 0 ]; then
    [ ${#CMD[@]} -eq 0 ] && CMD=(affinity)
    msg "Opening: ${FILES[*]}"
    CMD+=("${FILES[@]}")
fi

if [ -n "$AFFINITY_LOG" ]; then
    mkdir -p "$(dirname "$AFFINITY_LOG")" 2>/dev/null || true
    if : > "$AFFINITY_LOG" 2>/dev/null; then
        msg "Logging to $AFFINITY_LOG"
        # Not exec'd, so the log is complete even when the container dies: tee
        # needs to outlive it. PIPESTATUS carries the engine's real exit code.
        "$ENGINE" "${ARGS[@]}" "$IMAGE" "${CMD[@]}" 2>&1 | tee "$AFFINITY_LOG"
        exit "${PIPESTATUS[0]}"
    fi
    warn "Cannot write $AFFINITY_LOG -- continuing without a log."
fi

exec "$ENGINE" "${ARGS[@]}" "$IMAGE" "${CMD[@]}"
