#!/bin/bash
set -eE

mydir=$(dirname $0)
topdir=$mydir/..

. "$mydir/lib/misc.sh"

[ $# = 2 ] || die "Usage: $0 (<url>|<xcpng-version>) <destination>"
DIST="$1"
TARGET="$2"

case "$DIST" in
    *://*)
        SRCURL="$DIST"
        # TARGET unchanged
        ;;
    *)
        maybe_set_srcurl "$DIST"
        TARGET="$TARGET/$DIST"
        ;;
esac

command -v lftp >/dev/null || die "required tool not found: lftp"

lftp -c mirror \
     --verbose \
     --delete \
     --exclude="/Source/|-debuginfo-|-devel[-_]|/xs-opam-repo|/ocaml|/golang|/java" \
     "$SRCURL" "$TARGET"
