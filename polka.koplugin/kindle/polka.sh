#!/bin/sh
# Name: Полка
# Author: Полка для KOReader
# Icon: @@POLKA_DIR@@/kindle/icon.png
# DontUseFBInk
#
# The «Полка» launcher (SPDX-License-Identifier: AGPL-3.0-or-later).
# A scriptlet: the Kindle lists every .sh in /mnt/us/documents as a book and
# runs it when tapped. This one paints Polka's splash and starts KOReader the
# way KPM's own launcher does (without --kual, so KOReader prints nothing on
# the screen; "DontUseFBInk" above keeps this script's output off it too).
# Polka copies it here from its folder (О Полке → «Полка на экране Kindle»).

KOREADER_DIR="@@KOREADER_DIR@@"
POLKA_DIR="@@POLKA_DIR@@"

[ -x "${KOREADER_DIR}/koreader.sh" ] || [ -f "${KOREADER_DIR}/koreader.sh" ] || exit 0

# The screen's size, for the picture made for it: "1072x1448".
screen_size() {
    eips -i 2>/dev/null | awk '
        { for (i = 1; i < NF; i++) { if ($i == "xres:") x = $(i + 1); if ($i == "yres:") y = $(i + 1) } }
        END { if (x != "" && y != "") print x "x" y }'
}

splash() {
    size="$(screen_size)"
    [ -n "${size}" ] || size="1072x1448"
    png="${POLKA_DIR}/kindle/splash-${size}.png"
    [ -f "${png}" ] || return 0
    # eips draws a PNG of the screen's size; FBInk (shipped with KOReader) if eips can't
    # (/mnt/us is mounted noexec: FBInk runs from /var/tmp, as koreader.sh does it)
    eips -f -g "${png}" >/dev/null 2>&1 && return 0
    cp -pf "${KOREADER_DIR}/fbink" /var/tmp/fbink 2>/dev/null && chmod 777 /var/tmp/fbink
    /var/tmp/fbink -q -f -g file="${png}" >/dev/null 2>&1
}

splash

# as KPM's own launcher for KOReader does (launch.sh): from the folder above it;
# its lines («Starting KOReader . . .») go to the system log only, never to the screen
cd "${KOREADER_DIR%/*}" || exit 0
UNPACK_DIR="$(pwd)" exec sh "${KOREADER_DIR}/koreader.sh" --asap >/dev/null 2>&1
