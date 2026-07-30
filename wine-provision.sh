#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build-time helper: run one Wine provisioning command headlessly, then shut the
# prefix down cleanly.
#
# Two things make this necessary rather than just calling wine directly:
#
#  * Wine needs an X server even for unattended installers, hence Xvfb.
#  * After `wineboot`/winetricks, `services.exe` keeps running, so a plain
#    `wineserver -w` waits forever and the image build stalls at 0 % CPU. We
#    therefore ask for a graceful shutdown, wait briefly, and only then kill the
#    server outright.
#
# Usage:  WINE_STEP_TIMEOUT=900 wine-provision winetricks -q vcrun2022

TIMEOUT="${WINE_STEP_TIMEOUT:-900}"

timeout "$TIMEOUT" xvfb-run -a -s "-screen 0 1280x1024x24" "$@"
rc=$?

if [ "$rc" = "124" ]; then
    echo "wine-provision: '$*' timed out after ${TIMEOUT}s" >&2
fi

# Graceful first, forceful second -- either way we must not block.
wineboot --shutdown            >/dev/null 2>&1 || true
timeout 60 wineserver -w       >/dev/null 2>&1 || wineserver -k >/dev/null 2>&1 || true

exit $rc
