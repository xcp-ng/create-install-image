#!/bin/bash

set -e

ROOTDIR=$(pwd)
VERSION=8.3
YMD=$(date +%Y%m%d)
RPMARCH=x86_64

. "$ROOTDIR/scripts/lib/misc.sh"

usage() {
    cat <<EOF
Usage: $0 [<options>] <target>

Builds an install image and ISOs for XCP-ng $VERSION.

Arguments:
    <target>                  repo overlay to build from
                              usual values: updates, candidates, testing, ci, incoming

Options:
    --repo <DIR>              local repo mirror base directory (its $VERSION
                              subdir is used)
                              default: repo
    --repo-vates-tech <DIR>   local repo.vates.tech mirror base directory
                              (its $VERSION subdir is used; needed for linstor
                              packages)
                              default: repo/repo.vates.tech
    --sign-script <SCRIPT>   sign repomd using <SCRIPT>
                              default: don't sign
    -y|--yes                 don't ask for confirmation before proceeding
    -h|--help                show this help
EOF
}

REPO_BASE="$ROOTDIR/repo"
REPO_VATES_TECH_BASE="$ROOTDIR/repo/repo.vates.tech"
SIGNSCRIPT=
ASSUMEYES=0

while [ $# -ge 1 ]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --repo)
            [ $# -ge 2 ] || die_usage "$1 needs an argument"
            REPO_BASE="$2"
            shift
            ;;
        --repo-vates-tech)
            [ $# -ge 2 ] || die_usage "$1 needs an argument"
            REPO_VATES_TECH_BASE="$2"
            shift
            ;;
        --sign-script)
            [ $# -ge 2 ] || die_usage "$1 needs an argument"
            SIGNSCRIPT="$2"
            shift
            ;;
        -y|--yes)
            ASSUMEYES=1
            ;;
        -*)
            die_usage "unknown flag '$1'"
            ;;
        *)
            break
            ;;
    esac
    shift
done

[ $# -ge 1 ] || die_usage "<target> is mandatory"
[ $# -le 1 ] || die_usage "too many arguments"

TARGET="$1"
[ -d "$ROOTDIR/configs/$TARGET" ] || die_usage "unknown target '$TARGET' (no configs/$TARGET directory)"

# --repo/--repo-vates-tech (or their defaults) name the mirror's base
# directory; the actual per-version directory is always inferred from
# $VERSION rather than being part of the argument
REPO="$REPO_BASE/$VERSION"
REPO_VATES_TECH="$REPO_VATES_TECH_BASE/$VERSION"

# Check upfront for tools required by this script and by the scripts it
# calls (create-installimg.sh, create-iso.sh, lib/misc.sh)
REQUIRED_CMDS="sudo yum yumdownloader rpm2cpio createrepo_c genisoimage isohybrid mformat mmd mcopy bzip2 systemctl"
MISSING=
for _cmd in $REQUIRED_CMDS; do
    command -v "$_cmd" >/dev/null || MISSING="$MISSING $_cmd"
done
command -v grub2-mkimage >/dev/null || command -v grub-mkimage >/dev/null || MISSING="$MISSING grub2-mkimage or grub-mkimage"
# invoked as /sbin/depmod (absolute path) under sudo by create-installimg.sh,
[ -x /sbin/depmod ] || MISSING="$MISSING /sbin/depmod"
if [ -n "$SIGNSCRIPT" ]; then
    # gpg1 can be used by sign scripts (e.g. for signing with a GnuPG 1.x key);
    # gpg is used by create-iso.sh itself, after signing, to check the
    # digest algorithm strength of the resulting signature
    command -v gpg1 >/dev/null || MISSING="$MISSING gpg1"
    command -v gpg >/dev/null || MISSING="$MISSING gpg"
fi
[ -z "$MISSING" ] || die "missing required tool(s):$MISSING"

# make sure local package mirrors are present before starting a build that
# would otherwise fail partway through. mirror-repos.sh appends /$VERSION
# itself when given a plain xcp-ng version (hence $REPO_BASE below), but
# takes the destination as-is when given a URL (hence $REPO_VATES_TECH,
# already including /$VERSION, for the repo.vates.tech case)
[ -d "$REPO" ] || die "repo directory not found: $REPO (run: ./scripts/mirror-repos.sh $VERSION $REPO_BASE)"
[ -d "$REPO_VATES_TECH" ] || die "repo.vates.tech directory not found: $REPO_VATES_TECH, needed for linstor packages (run: ./scripts/mirror-repos.sh https://repo.vates.tech/xcp-ng/8/$VERSION $REPO_VATES_TECH)"

SIGN_SCRIPT_ARGS=()
NOSIGN_SUFFIX=".nosign"
if [ -n "$SIGNSCRIPT" ]; then
    SIGN_SCRIPT_ARGS=(--sign-script "$SIGNSCRIPT")
    NOSIGN_SUFFIX=
fi

IMG="install-$VERSION.$TARGET.img"
ISO_LINSTOR="xcp-ng-$VERSION-$YMD-linstor-upgradeonly.$TARGET$NOSIGN_SUFFIX.iso"
ISO_PLAIN="xcp-ng-$VERSION-$YMD.$TARGET$NOSIGN_SUFFIX.iso"
ISO_NETINSTALL="xcp-ng-$VERSION-$YMD-netinstall.$TARGET.iso"

cat <<EOF
About to build XCP-ng $VERSION from target '$TARGET', producing:
  - $IMG
  - $ISO_LINSTOR
  - $ISO_PLAIN
  - $ISO_NETINSTALL
Repo: $REPO
Repo.vates.tech (linstor packages): $REPO_VATES_TECH
Signing: ${SIGNSCRIPT:-none (ISOs will be unsigned)}
Any of the above files that already exist will be replaced.
Make sure your local mirrors are up to date.
WARNING: regardless of target '$TARGET', linstor packages are for now always
pulled from the main (non-testing) repo.vates.tech linstor repo.
EOF

if [ "$ASSUMEYES" != 1 ]; then
    read -r -p "Proceed? [y/N] " reply
    case "$reply" in
        y|Y) ;;
        *) die "Aborted." ;;
    esac
fi

set -x

sudo ./scripts/create-installimg.sh \
    --force-overwrite \
    --srcurl "file://$REPO" \
    --output "$IMG" \
    $VERSION:$TARGET

# With linstor support
LINSTOR_MULTIVER_PKGS=$(cd "$REPO_VATES_TECH/linstor/$RPMARCH/Packages/" && for rpm in *linstor*.rpm; do basename $rpm .rpm; done)
# Remove older linstor packages from LINSTOR_MULTIVER_PKGS
# They're packages that were never supported in 8.3 and older than what 8.2 has
LINSTOR_MULTIVER_PKGS=$(echo "$LINSTOR_MULTIVER_PKGS" | grep -Fvw \
    -e linstor-client-1.18.0-1.noarch \
    -e linstor-common-1.21.1-1.el7.noarch \
    -e linstor-controller-1.21.1-1.el7.noarch \
    -e linstor-satellite-1.21.1-1.el7.noarch \
    -e python-linstor-1.18.0-1.noarch \
    -e xcp-ng-linstor-1.2-1.xcpng8.3.noarch \
    | xargs)
./scripts/create-iso.sh \
    --srcurl "file://$REPO" \
    --srcurl:linstor "file://$REPO_VATES_TECH" \
    --output "$ISO_LINSTOR" \
    --extra-packages "xcp-ng-release-linstor $LINSTOR_MULTIVER_PKGS" \
    "${SIGN_SCRIPT_ARGS[@]}" \
    --force-overwrite \
    -V "XCP-NG $VERSION $YMD LINSTOR" \
    $VERSION:$TARGET:linstor \
    "$IMG"

./scripts/create-iso.sh \
    --srcurl "file://$REPO" \
    --output "$ISO_PLAIN" \
    "${SIGN_SCRIPT_ARGS[@]}" \
    --force-overwrite \
    -V "XCP-NG $VERSION $YMD" \
    $VERSION:$TARGET \
    "$IMG"

./scripts/create-iso.sh \
    --netinstall \
    --srcurl "file://$REPO" \
    --output "$ISO_NETINSTALL" \
    --force-overwrite \
    -V "XCP-NG $VERSION $YMD" \
    $VERSION:$TARGET \
    "$IMG"
