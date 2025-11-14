#!/bin/bash
set -eE

mydir=$(dirname $0)
topdir=$mydir/..

. "$mydir/lib/misc.sh"

maybe_set_srcurl() {
    [ $# = 1 ] || die "maybe_set_srcurl: need exactly 1 argument"
    DIST="$1"
    MINOR=${DIST%.*}
    MAJOR=${MINOR%.*}
    if [ "$MAJOR" = "$MINOR" ]; then
	# DIST only has 2 components
	MINOR="$DIST"
    fi
    SRCURL_DEFAULT="https://updates.xcp-ng.org/$MAJOR/$MINOR"
    if [ -z "$SRCURL" ]; then
	SRCURL="$SRCURL_DEFAULT"
	[ -z "$VERBOSE" ] || echo "Defaulting to SRCURL '$SRCURL'"
    fi
}


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
     --exclude="/Source/|-debuginfo-|-debug-|-devel[-_]|/xs-opam-repo|/ocaml|/golang" \
     "$SRCURL" "$TARGET"
