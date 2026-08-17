#!/bin/sh
# build.sh -- assemble the ripple keymap into a (vial-)qmk tree and compile it.
# Reuses the board's stock keymap.c and layers our effect + config on top, so
# the effect stays board-agnostic and the keymap is generated, not vendored.
#   VIAL_QMK=~/src/vial-qmk sh qmk/build.sh drop/cstm65 [keymap-name]
set -eu
QMK=${VIAL_QMK:-$HOME/src/vial-qmk}
BOARD=${1:?board path, e.g. drop/cstm65}
KM=${2:-ripple}
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$QMK/keyboards/$BOARD
[ -d "$SRC/keymaps/default" ] || { echo "no default keymap under $SRC" >&2; exit 1; }
DST=$SRC/keymaps/$KM
mkdir -p "$DST"
cp "$SRC/keymaps/default/keymap.c" "$DST/keymap.c"
cp "$HERE/rgb_matrix_user.inc"     "$DST/rgb_matrix_user.inc"
cp "$HERE/keymap/config.h"         "$DST/config.h"
cp "$HERE/keymap/rules.mk"         "$DST/rules.mk"
echo "assembled $DST; compiling ..."
cd "$QMK"
exec qmk compile -kb "$BOARD" -km "$KM"
