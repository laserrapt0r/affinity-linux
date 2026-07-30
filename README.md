# Affinity in a container (Wine + GPU)

Runs **Affinity 3** (the unified Canva/Serif app for Windows) isolated in an OCI
container on Linux, under Wine, with GPU acceleration.

The image contains only Wine and its runtime — **Affinity itself is downloaded at
first start** into a data volume. That keeps the image free of proprietary
payload, so it can be published and rebuilt by anyone.

Works with **Podman (rootless, recommended)** and **Docker**.

Verified working on Ubuntu 24.04, X11, with an NVIDIA RTX 4070 Laptop + AMD
Radeon 780M hybrid setup: Affinity 3.2.3.4646 starts, creates and renders
documents, and registers on the GPU.

---

## Quick start

```bash
# 1. Host preparation (NVIDIA only; skip on AMD/Intel)
sudo ./setup-host.sh

# 2. Build (takes a while -- .NET 4.8 under Wine is slow)
podman build -t affinity-wine:latest .

# 3. Run
./run-affinity.sh
```

On first start the container unpacks the prebuilt Wine prefix into the volume,
downloads Affinity (~640 MiB) and launches it. Later starts go straight to the
app.

> **On first launch Affinity asks whether to upload crash reports. Answer No.**
> Accepting is a known WineFix-unfixed bug that puts the app into a permanent
> crash loop.

---

## Why this is not just "wine setup.exe"

Five things make Affinity awkward under Wine. Each one is handled here, and each
was a hard failure before it was:

| Problem | What this image does |
|---|---|
| `Affinity.exe` is a **.NET Framework 4.x / WPF** assembly, not a plain Win32 binary. Wine-Mono cannot run it. | Removes Wine-Mono and installs genuine **.NET Framework 4.8** via winetricks, plus `vcrun2022`. |
| The download is an **MSIX**, and Wine has no AppX deployment service — the installer simply cannot run. | An MSIX is a ZIP. The entrypoint unpacks it and launches the contained `App/Affinity.exe` directly (the manifest declares `Windows.FullTrustApplication`, i.e. an ordinary Win32 app in an MSIX wrapper). |
| Affinity hosts its Canva sign-in in **WebView2**, which cannot be installed under Wine. Without it the WPF message loop dies with an `SEHException` a minute or two after the UI appears. | Ships **AffinityPluginLoader + WineFix**, which patches that dialog out (and several other Wine bugs) at the .NET level. |
| X11's **MIT-SHM** extension uses SysV shared memory, which is scoped to the IPC namespace. The app crashes the instant it paints a canvas. | The launcher runs with `--ipc=host`. |
| Affinity renders through Direct3D. | Ships **vkd3d-proton** (D3D12) and **DXVK** (D3D9/10/11), selectable at runtime. |

Older guides also require `WinMetadata` files copied from a real Windows install
plus ElementalWarrior's patched `wintypes.dll`. **This is no longer needed** —
the image pins **Wine 11.x**, which provides the required WinRT metadata support
itself.

One more trap worth naming, because it silently wedges unattended installs: the
very first `wineboot` pops up the *"install Mono / Gecko?"* dialogs. With no
window manager there is nothing to click, and the build hangs forever at 0 % CPU.
The build therefore runs that one command with `WINEDLLOVERRIDES="mscoree,mshtml="`
to suppress both — and only that command, since `mscoree` is the .NET loader that
everything afterwards depends on. Every Wine step additionally runs under a
`timeout`, so a stuck dialog fails the build instead of stalling it.

---

## Requirements

Everything Affinity needs — Wine, .NET, Mesa, DXVK — is inside the image. The
host only has to provide a container engine, an X server and a few small
utilities.

**Strictly required: a container engine and an X server.** Everything else is
used opportunistically; the scripts check for each tool and degrade instead of
failing. In practice you still want `xauth`, or the container will not be allowed
to talk to your X server, and the desktop helpers, or menu entries and file
associations will not refresh until your next login.

### Host packages

**Debian / Ubuntu**

```bash
sudo apt install podman uidmap slirp4netns fuse-overlayfs \
    xauth x11-xserver-utils \
    xdg-utils desktop-file-utils shared-mime-info gtk-update-icon-cache unzip
```

**Arch**

```bash
sudo pacman -S podman \
    xorg-xauth xorg-xrdb \
    xdg-utils desktop-file-utils shared-mime-info gtk-update-icon-cache unzip
```

**Fedora**

```bash
sudo dnf install podman \
    xorg-x11-xauth xrdb \
    xdg-utils desktop-file-utils shared-mime-info gtk-update-icon-cache unzip
```

What each one is for:

| Provides | Needed by | Without it |
|---|---|---|
| `podman` (or `docker`) | everything | nothing works |
| `uidmap`, `slirp4netns`, `fuse-overlayfs` | rootless Podman on Debian/Ubuntu | rootless containers fail; Arch and Fedora pull these in themselves |
| `xauth` | `run-affinity.sh` | no X cookie is built, and the X server refuses the container |
| `xrdb` | HiDPI detection | falls back to GNOME settings, then to 96 DPI |
| `xdg-utils`, `desktop-file-utils`, `shared-mime-info`, `gtk-update-icon-cache` | `install-desktop.sh` | menu entry and associations are written but caches are not refreshed until re-login |
| `unzip` | `install-desktop.sh` fallback | icons are read from the data volume instead, which works once Affinity has been started |

Deliberately *not* on this list: Python, Wine, winetricks and any .NET runtime.
Wine and its dependencies live in the image, and the host scripts are plain
POSIX shell plus `awk`.

Using Docker instead of Podman? Substitute `docker` for `podman` above. Note
that adding yourself to the `docker` group grants effective root on the host —
see [Isolation, and what it costs](#isolation-and-what-it-costs).

### NVIDIA GPUs

`nvidia-container-toolkit` is what lets a container see the GPU. On Arch it is in
`extra`; on Debian, Ubuntu and Fedora it comes from NVIDIA's own repository, not
from the distribution.

**Arch**

```bash
sudo pacman -S nvidia-container-toolkit
```

**Debian / Ubuntu**

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update && sudo apt install nvidia-container-toolkit
```

**Fedora**

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
  | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo
sudo dnf install nvidia-container-toolkit
```

Then, on every distribution:

```bash
sudo ./setup-host.sh
```

**AMD / Intel GPUs need none of this.** The launcher passes `/dev/dri` through and
Mesa is already in the image.

### Why `setup-host.sh` exists

`nvidia-ctk cdi generate` emits a **CDI 0.7.0** spec, while Podman 4.x (Ubuntu
24.04 ships 4.9.3) only understands up to 0.6.0. It rejects the 0.7-only
`additionalGids` field and reports

```
Error: setting up CDI devices: unresolvable CDI devices nvidia.com/gpu=all
```

which points nowhere near the actual cause. The script downgrades the spec
version, strips that field, and removes the stale duplicate the toolkit also
writes to `/var/run/cdi/`. On Podman 5+ / Docker it leaves the spec alone.

Re-run it after every driver update — the spec pins driver library paths.

---

## Usage

```bash
./run-affinity.sh              # start Affinity
./run-affinity.sh shell        # shell inside the container
./run-affinity.sh winecfg      # Wine configuration
./run-affinity.sh reinstall    # re-download + re-unpack Affinity (e.g. to update)
```

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `AFFINITY_DPI` | auto | Display scaling in DPI. `96` = 100 %, `144` = 150 %, `192` = 200 %. Auto-detected from the desktop |
| `AFFINITY_RENDERER` | `vkd3d` | `vkd3d` (D3D12 only), `dxvk` (DXVK + vkd3d), `wined3d` (no Vulkan translation) |
| `AFFINITY_APL` | `1` | `0` disables AffinityPluginLoader/WineFix — expect the sign-in crash |
| `AFFINITY_IPC` | `host` | `private` keeps the IPC namespace separate — expect the MIT-SHM crash |
| `AFFINITY_GPU` | auto | `nvidia` or `amd` to pin one Vulkan device |
| `AFFINITY_ENGINE` | auto | `podman` or `docker` |
| `AFFINITY_VOLUME` | `affinity-data` | Name of the data volume |
| `AFFINITY_MOUNTS` | — | Extra bind mounts, e.g. `"$HOME/Bilder:/data/Bilder"` |
| `WINEDEBUG` | `-all` | Set to `+err,+warn` when debugging |

Example — expose your pictures folder and force the discrete GPU:

```bash
AFFINITY_GPU=nvidia AFFINITY_MOUNTS="$HOME/Bilder:/data/Bilder" ./run-affinity.sh
```

### Desktop integration

```bash
./install-desktop.sh              # menu entry, icons, file associations
./install-desktop.sh --uninstall
```

This installs into `~/.local/share` only — no root, nothing outside your home
directory:

* **Menu entry** with `StartupWMClass=affinity.exe`, so the running window groups
  under the launcher icon in the dock or task bar instead of appearing as a
  second, iconless entry.
* **Icons** in all seven theme sizes (16–256 px), taken from *your own* Affinity
  download — the MSIX ships them, so nothing proprietary is committed here. The
  unplated variants are preferred, as they have no baked-in background tile.
* **File associations** for `.af`, `.afdesign`, `.afphoto`, `.afpub`,
  `.aftemplate` and `.afpackage`, registered as the default handler. Double-click
  a document and it opens: the launcher bind-mounts the file's directory at the
  identical path in the container and passes Affinity the Wine equivalent
  (`/home/you/x.afdesign` → `Z:\home\you\x.afdesign`, since Wine maps `Z:` to `/`).
* **Right-click actions** on the launcher for *Wine configuration* and
  *Reinstall / update Affinity*.

Everything here is plain freedesktop.org, so it works the same on GNOME, KDE
Plasma, XFCE and Cinnamon: `~/.local/share/applications` for the entry, the
`hicolor` theme for icons (Breeze and Adwaita both fall back to it), and
`xdg-mime` writing `mimeapps.list`, which Plasma and GNOME read alike.
`StartupWMClass` is honoured by both GNOME Shell and Plasma's task manager.

Run it once after the first Affinity launch, so the icons can be pulled from the
data volume. Some desktops need a re-login to notice new icons.

Tested on GNOME/X11. The mechanisms are desktop-agnostic, but Plasma and XFCE
have not been verified here.

### HiDPI displays

Wine hands applications a fixed 96 DPI regardless of what the desktop uses, so
on a scaled screen Affinity comes up at half or a third of the size of
everything around it. The launcher works the scaling out and passes it in; the
entrypoint writes it to `LogPixels` in the prefix, the same setting winecfg's
screen-resolution slider changes.

Detection order:

1. `Xft.dpi` from the X resource database — set by GNOME, KDE and most desktops
   on X11, and the only one needed in practice there
2. GNOME's `scaling-factor`, then `text-scaling-factor`
3. KDE Plasma's `forceFontDPI`, then `ScaleFactor`, from `kdeglobals` — Plasma
   does not always set `Xft.dpi` under Wayland
4. Failing all of that, 96

Anything outside 96–384 DPI is treated as a detection bug and discarded, since a
bad reading produces a window thousands of pixels wide.

Affinity is a WPF application and honours the system DPI, so the interface is
re-rendered at the higher resolution rather than scaled up: it stays sharp.

Override the automatic detection when it guesses wrong:

```bash
AFFINITY_DPI=144 ./run-affinity.sh     # 150 %
AFFINITY_DPI=96  ./run-affinity.sh     # unscaled
```

The value is remembered in the prefix, so it only has to be set once. Changing
it later takes effect on the next start.

#### Monitors with different scaling

Dragging the window to a monitor with a different scale **does not** rescale the
interface. `LogPixels` is a single value per Wine prefix, read once at startup,
and Wine's X11 driver has no per-monitor DPI to update it from — so the
compositor bitmap-scales the window instead and it looks soft or mis-sized on
the second screen.

This is not a container limitation: a native Wine installation behaves
identically. X11 compounds it, since mixed scaling there is emulated by scaling
the whole screen — which is why `Xft.dpi` is one global number to begin with.

The practical approach is to set the DPI of the monitor you use Affinity on
most, and to restart it with an explicit value when you work on the other one:

```bash
AFFINITY_DPI=96 ./run-affinity.sh
```

Close Affinity first — the Wine prefix holds a lock, so a second instance
against the same volume is not a way around this.

### What lives where

Everything persistent is in the `affinity-data` volume:

* `/data/prefix` — the Wine prefix, including Affinity's settings
* `/data/affinity` — the unpacked application
* `/data/cache` — the downloaded MSIX

Reset everything with `podman volume rm affinity-data`.

---

## Portability

The image is built `FROM ubuntu:24.04` and carries its own Wine, .NET and Mesa,
so **the host distribution does not matter** — Arch, Fedora, openSUSE, Debian all
work. Only four things are asked of the host:

| Requirement | Notes |
|---|---|
| Podman or Docker | Rootless Podman needs a subuid/subgid range. Debian and Ubuntu set this up automatically; **Arch and minimal installs often do not** — `setup-host.sh` checks and fixes it |
| X11 or XWayland | On a Wayland session this runs against XWayland, which every mainstream desktop provides |
| `nvidia-container-toolkit` | NVIDIA only. `setup-host.sh` gives the right install command for your distro |
| `/dev/dri` | AMD/Intel. Nothing to install; Mesa lives in the image |

Notes for specific distributions:

* **Arch and Fedora** currently ship **Podman 6.x**, which understands CDI 0.7
  natively — `setup-host.sh` detects this and skips the spec downgrade that
  Ubuntu's Podman 4.9 needs. Arch also has `nvidia-container-toolkit` in `extra`,
  so no extra repository is required there.
* Package names per distribution are in [Host packages](#host-packages).
* **NVIDIA driver version does not need to match** anything in the image — the
  container runtime injects the host's own driver libraries. Just re-run
  `setup-host.sh` after a driver update, since the CDI spec pins library paths.

Nothing in the scripts is specific to this machine: GPU, DPI and container
engine are all detected at runtime.

## Building

```bash
podman build -t affinity-wine:latest .        # or: docker build ...
```

Expect **25–35 minutes** for a cold build and roughly 9 GB. Almost all of that is
`winetricks dotnet48`, which runs Microsoft's real .NET 4.8 installer under Wine.
Every provisioning step is its own layer, so a repeated build reuses everything
up to the first change.

Pinned versions are build arguments — override them individually:

| Argument | Default | |
|---|---|---|
| `WINE_BRANCH` | `devel` | `staging` or `stable` also work |
| `WINE_VERSION` | `11.14~noble-1` | Must exist in the WineHQ repository |
| `DXVK_VERSION` | `3.0.2` | |
| `VKD3D_VERSION` | `3.0.1` | |
| `APL_VERSION` | `0.3.0` | AffinityPluginLoader + WineFix |

```bash
podman build --build-arg WINE_VERSION=11.15~noble-1 -t affinity-wine:latest .
```

Two things to know when maintaining this:

* The WineHQ apt line hardcodes the `noble` codename to match `ubuntu:24.04`.
  Bumping the base image means changing both together.
* `ARG APL_VERSION` sits immediately above the step that uses it, not with the
  other arguments at the top. An `ARG` invalidates every layer below it, and up
  there a version bump would force the 20-minute .NET layer to rebuild.

The build needs network access to `archive.ubuntu.com`, `dl.winehq.org`,
`github.com` and Microsoft's download servers. It does **not** download Affinity —
that happens at first run.

## Isolation, and what it costs

Under rootless Podman there is no root daemon, and `--userns=keep-id` maps your
host user 1:1 so files in bind mounts stay yours. Two concessions are made for a
GUI application:

* `--ipc=host` — required for MIT-SHM, as above. This shares the SysV IPC
  namespace with the host.
* The X11 socket is mounted. The launcher builds a temporary `Xauthority` cookie
  re-stamped as `FamilyWild` rather than resorting to `xhost +`.

Adding your user to the `docker` group would grant effective root on the host and
undercut all of this. Use rootless Podman, or `sudo docker`.

### Why not Flatpak or Snap?

* **Flatpak** is a reasonable technical fit — bubblewrap sandboxing with
  first-class GPU and display integration (it is how Bottles runs Wine). The
  downsides here: `flatpak-builder` manifests are considerably more involved,
  distribution means running your own repo or getting onto Flathub, and a
  Wine + .NET stack on a Flatpak runtime is more fragile than a plain Ubuntu base.
* **Snap** fights Wine's use of namespaces and executable memory, and GPU access
  outside the blessed interfaces is painful.
* **A container** gives the strongest isolation-per-effort, is a single
  self-contained recipe to publish, and rebuilds identically for anyone.

---

## Known limitations

* **Canva sign-in does not work.** WineFix patches the prompt out because
  WebView2 is unavailable; anything requiring the account (sync, Canva AI) is
  therefore out of reach.
* **Help / in-app web views** are unavailable for the same reason.
* Declining the crash-report prompt is mandatory (see above).
* OpenCL is exposed for NVIDIA only. Mesa's OpenCL for AMD is not installed.

---

## Troubleshooting

**`Cannot reach X server`** — the launcher builds a temporary `Xauthority`
cookie; check that `xauth` is installed. Last resort: `xhost +SI:localuser:$(id -un)`.

**Only `llvmpipe` in the Vulkan device list** — no GPU reached the container. For
NVIDIA verify `/etc/cdi/nvidia.yaml` matches the current driver (`sudo ./setup-host.sh`);
for AMD check that `/dev/dri/renderD*` was passed through.

**`cannot set shmsize when running in the {host } IPC Namespace`** — `--shm-size`
and `--ipc=host` are mutually exclusive in Podman. The launcher already handles
this; only relevant if you invoke `podman run` by hand.

**Crash right after the UI appears** — check for
`SEHException` in the output. That is the WebView2 path; make sure
`AFFINITY_APL` is not set to `0`.

---

## Credits and licences

This repository is **[MIT licensed](LICENSE)** and contains nothing but build
instructions: a Dockerfile, shell scripts and this document. No third-party code
is bundled — every component is fetched from its own upstream at build or run
time and keeps its own licence:

| Component | Licence |
|---|---|
| [Wine](https://www.winehq.org/) | LGPL-2.1-or-later |
| [DXVK](https://github.com/doitsujin/dxvk) | Zlib |
| [vkd3d-proton](https://github.com/HansKristian-Work/vkd3d-proton) | LGPL-2.1-or-later |
| [AffinityPluginLoader](https://github.com/noahc3/AffinityPluginLoader) | MIT |
| WineFix (APL plugin) | GPL-2.0 |
| `d2d1.dll` bundled with WineFix | LGPL-2.1 |
| Microsoft .NET Framework 4.8, VC++ runtime | proprietary, Microsoft redistributables |

MIT is the appropriate choice here precisely *because* nothing is vendored. The
GPL-2.0 licence on WineFix would matter if this repository shipped or linked
against it; it does not. A built image ends up holding software under several
licences side by side, which is mere aggregation rather than a combined work —
these scripts install and invoke those components, they neither link against nor
derive from them. Picking a copyleft licence for the scripts would only have
created a needless friction point with that GPL-2.0-only component.

Affinity itself is proprietary software belonging to Canva. It is downloaded from
the vendor at first run under the vendor's terms, and is neither included here
nor redistributed. See [LICENSE](LICENSE) for the full breakdown.

The Wine setup follows the groundwork of the
[AffinityOnLinux](https://github.com/seapear/AffinityOnLinux) community.
