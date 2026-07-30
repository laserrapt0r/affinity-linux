# syntax=docker/dockerfile:1.7
#
# Affinity (Canva/Serif) v3 in a container, running under Wine.
#
# Design notes
# ------------
#  * Affinity.exe is a .NET Framework 4.x / WPF assembly (see README), so the
#    prefix needs the *real* Microsoft .NET 4.8 -- Wine-Mono is removed.
#  * The Wine prefix is fully provisioned at BUILD time into /opt/wine-template
#    and copied into the data volume on first start. That keeps first launch
#    fast and the result reproducible.
#  * Affinity itself is NOT baked into the image. It is downloaded at RUNTIME
#    into the data volume, so this image stays free of proprietary payload and
#    can be published as-is.
#
FROM ubuntu:24.04

ARG WINE_BRANCH=devel
ARG WINE_VERSION=11.14~noble-1
ARG DXVK_VERSION=3.0.2
ARG VKD3D_VERSION=3.0.1
ARG PUID=1000
ARG PGID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

# --------------------------------------------------------------------------
# 1. Base system + WineHQ repository
# --------------------------------------------------------------------------
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg2 unzip p7zip-full cabextract \
        xz-utils xvfb x11-utils xdg-utils procps util-linux locales \
        fonts-liberation fonts-dejavu-core \
        libgl1 libglx-mesa0 libegl1 libgles2 \
        mesa-vulkan-drivers mesa-vulkan-drivers:i386 \
        libvulkan1 libvulkan1:i386 vulkan-tools \
        mesa-va-drivers ocl-icd-libopencl1 clinfo \
        libgtk-3-0t64 libgdk-pixbuf-2.0-0 librsvg2-common \
        gstreamer1.0-plugins-good gstreamer1.0-libav \
        zenity desktop-file-utils && \
    mkdir -pm755 /etc/apt/keyrings && \
    wget -qO /etc/apt/keyrings/winehq.asc https://dl.winehq.org/wine-builds/winehq.key && \
    echo "deb [signed-by=/etc/apt/keyrings/winehq.asc] https://dl.winehq.org/wine-builds/ubuntu noble main" \
        > /etc/apt/sources.list.d/winehq.list && \
    apt-get update && \
    apt-get install -y --install-recommends \
        winehq-${WINE_BRANCH}=${WINE_VERSION} \
        wine-${WINE_BRANCH}=${WINE_VERSION} \
        wine-${WINE_BRANCH}-amd64=${WINE_VERSION} \
        wine-${WINE_BRANCH}-i386=${WINE_VERSION} && \
    rm -rf /var/lib/apt/lists/*

# Pinned winetricks (the Ubuntu package lags badly behind).
RUN wget -qO /usr/local/bin/winetricks \
        https://raw.githubusercontent.com/Winetricks/winetricks/20250102/src/winetricks && \
    chmod +x /usr/local/bin/winetricks

ENV PATH="/opt/wine-${WINE_BRANCH}/bin:${PATH}"

COPY wine-provision.sh /usr/local/bin/wine-provision
RUN chmod +x /usr/local/bin/wine-provision

# --------------------------------------------------------------------------
# 2. Unprivileged user. HOME is /data so that the prefix built here uses the
#    exact same absolute paths it will have at runtime.
# --------------------------------------------------------------------------
#    Ubuntu 24.04 ships a stock 'ubuntu' user on 1000:1000 -- clear the way first.
RUN set -eux; \
    if getent passwd ${PUID} >/dev/null; then \
        userdel -r "$(getent passwd ${PUID} | cut -d: -f1)" 2>/dev/null || true; \
    fi; \
    if getent group ${PGID} >/dev/null; then \
        groupdel "$(getent group ${PGID} | cut -d: -f1)" 2>/dev/null || true; \
    fi; \
    groupadd -g ${PGID} affinity; \
    useradd -u ${PUID} -g ${PGID} -m -d /data -s /bin/bash affinity; \
    mkdir -p /data; chown -R ${PUID}:${PGID} /data

ENV HOME=/data \
    WINEPREFIX=/data/prefix \
    WINEARCH=win64 \
    WINEDEBUG=-all

# --------------------------------------------------------------------------
# 3. Provision the Wine prefix (the slow part -- each verb is its own layer
#    so a failure does not invalidate the previous ones).
# --------------------------------------------------------------------------
USER affinity

# mscoree/mshtml are disabled *for this command only*: otherwise Wine pops up
# the "install Mono / Gecko?" dialogs, which nothing can click under Xvfb and
# the build hangs forever. They must be back on afterwards -- mscoree is the
# .NET loader that dotnet48 and Affinity depend on.
RUN WINE_STEP_TIMEOUT=600 wine-provision \
        env WINEDLLOVERRIDES="mscoree,mshtml=" wineboot --init

# Belt and braces: if a Mono package ever does land in the prefix, drop it --
# Affinity needs the genuine .NET Framework, not Mono.
RUN WINE_STEP_TIMEOUT=600 wine-provision winetricks -q --force remove_mono || true

RUN WINE_STEP_TIMEOUT=900 wine-provision winetricks -q vcrun2022

# .NET Framework 4.8 -- slow (10-20 min) and the single most fragile step.
RUN WINE_STEP_TIMEOUT=2700 wine-provision winetricks -q dotnet48

RUN WINE_STEP_TIMEOUT=900 wine-provision winetricks -q corefonts

# Report as Windows 11 (must come after dotnet48, which forces win7).
RUN WINE_STEP_TIMEOUT=300 wine-provision winetricks -q win11

# --------------------------------------------------------------------------
# 4. D3D -> Vulkan translation layers
# --------------------------------------------------------------------------
#    zstd is installed here rather than in the base layer so that changing it
#    does not invalidate the (very expensive) .NET layer above.
USER root
RUN set -eux; \
    apt-get update; apt-get install -y --no-install-recommends zstd; \
    rm -rf /var/lib/apt/lists/*; \
    cd /tmp; \
    wget -qO dxvk.tar.gz "https://github.com/doitsujin/dxvk/releases/download/v${DXVK_VERSION}/dxvk-${DXVK_VERSION}.tar.gz"; \
    tar xf dxvk.tar.gz; \
    mkdir -p /opt/dxvk; cp -r dxvk-${DXVK_VERSION}/* /opt/dxvk/; \
    wget -qO vkd3d.tar.zst "https://github.com/HansKristian-Work/vkd3d-proton/releases/download/v${VKD3D_VERSION}/vkd3d-proton-${VKD3D_VERSION}.tar.zst"; \
    tar --zstd -xf vkd3d.tar.zst; \
    mkdir -p /opt/vkd3d; cp -r vkd3d-proton-${VKD3D_VERSION}/* /opt/vkd3d/; \
    rm -rf /tmp/dxvk* /tmp/vkd3d*; \
    ls -R /opt/dxvk /opt/vkd3d | head -40

# Affinity's hardware acceleration goes through OpenCL. The NVIDIA container
# runtime injects libnvidia-opencl.so.1 but not the ICD registration file that
# tells the loader about it, so OpenCL silently finds zero platforms. Writing it
# here is harmless on machines without an NVIDIA GPU -- the loader just skips an
# ICD whose library is missing.
RUN mkdir -p /etc/OpenCL/vendors && \
    echo "libnvidia-opencl.so.1" > /etc/OpenCL/vendors/nvidia.icd

# --------------------------------------------------------------------------
# 4b. AffinityPluginLoader + WineFix
#
# Affinity hosts parts of its UI (Canva sign-in, help) in Microsoft's WebView2
# runtime. WebView2 cannot currently be installed under Wine -- its installer
# hangs and the COM classes never register -- and when Affinity fails to find
# it, the WPF message loop dies with
#   Unhandled Exception: System.Runtime.InteropServices.SEHException
# taking the whole app down a minute or two after the UI has come up.
#
# WineFix (a plugin for APL) patches out that sign-in dialog at the .NET level
# via Harmony, along with several other Wine-specific bugs, and ships a patched
# d2d1.dll. It is staged here and applied to the app directory at runtime,
# because an Affinity update replaces that directory wholesale.
#
# APL is MIT, WineFix GPLv2, the bundled d2d1.dll LGPLv2.1 -- see
# https://github.com/noahc3/AffinityPluginLoader
#
# Declared here rather than at the top of the file on purpose: an ARG
# invalidates every layer below it, and up there it would force the very
# expensive .NET layer to rebuild whenever the APL version is bumped.
# --------------------------------------------------------------------------
ARG APL_VERSION=0.3.0
RUN set -eux; \
    wget -qO /tmp/apl.tar.xz \
        "https://github.com/noahc3/AffinityPluginLoader/releases/download/v${APL_VERSION}/affinitypluginloader-plus-winefix.tar.xz"; \
    mkdir -p /opt/apl; \
    tar xJf /tmp/apl.tar.xz -C /opt/apl; \
    rm /tmp/apl.tar.xz; \
    chown -R ${PUID}:${PGID} /opt/apl; \
    ls -R /opt/apl

# --------------------------------------------------------------------------
# 5. Freeze the provisioned prefix as a template, so the (volume-mounted)
#    /data can be empty on first start.
# --------------------------------------------------------------------------
RUN mv /data/prefix /opt/wine-template && \
    chown -R ${PUID}:${PGID} /opt/wine-template /opt/dxvk /opt/vkd3d

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV AFFINITY_MSIX_URL="https://downloads.affinity.studio/Affinity%20x64.msix" \
    AFFINITY_RENDERER=vkd3d \
    AFFINITY_APL=1 \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,graphics,display \
    NVIDIA_VISIBLE_DEVICES=all

VOLUME ["/data"]
WORKDIR /data

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["affinity"]
