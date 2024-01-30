#!/bin/bash
set -e
set -o pipefail

# nickname for the key file
KEYNICK="MY-ORG"
# id of the gpg1 key
KEYID="test@example.com"

mydir=$(dirname $0)
topdir=$mydir/..

. "$mydir/lib/misc.sh"

usage() {
    cat <<EOF
Usage: $0 <iso-directory>
EOF
}

command -v gpg1 >/dev/null || die "required tool not found: gpg1 (gnupg1)"

[ $# = 1 ] || die_usage "takes one argument"
ISODIR="$1"
[ -f "$ISODIR/repodata/repomd.xml" ] || die_usage "$ISODIR does not contain a yum repo"

gpg1 --default-key="$KEYID" --armor --detach-sign "$ISODIR/repodata/repomd.xml"
gpg1 --armor -o "$ISODIR/RPM-GPG-KEY-$KEYNICK" --export "$KEYID"
sed -i "s,key1 = .*,key1 = RPM-GPG-KEY-$KEYNICK," \
    $ISODIR/.treeinfo
