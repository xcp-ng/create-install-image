#!/bin/bash
#
# DEMONSTRATOR: build the prebuilt dom0 root filesystem image (rootfs.tar.zst)
# that host-installer can unpack instead of running dnf (see the
# "install from a prebuilt rootfs image" host-installer patch).
#
# dnf runs chrooted inside the installer root filesystem (install.img) itself,
# so the transaction is resolved and installed by the very dnf/rpm that would
# otherwise run at install time, with the same configuration.
#
# Must run as root (as in the build container), or as root of a user and mount
# namespace, e.g.: podman unshare unshare -m --propagation private <this script>

set -euo pipefail

die() { echo >&2; echo >&2 "ERROR: $*"; echo >&2; exit 1; }
die_usage() { usage >&2; die "$*"; }

usage() {
    cat <<EOF
Usage: $0 <package-list> <install.img> <repo-dir> <output.tar.zst>

  <package-list>  packages to install (one per line, '#' comments allowed)
  <install.img>   installer root filesystem image produced by create-installimg.sh
  <repo-dir>      yum repository the image is built from (the ISO tree, after createrepo)
  <output>        rootfs image to write
EOF
}

[ $# = 4 ] || die_usage "wrong number of arguments"
PKGLIST=$(realpath "$1"); INSTALLIMG=$(realpath "$2"); REPODIR=$(realpath "$3"); OUTPUT=$(realpath -m "$4")
[ "$(id -u)" = 0 ] || die "must run as root (or in a user namespace, see header)"
for tool in cpio zstd tar chroot; do
    command -v $tool >/dev/null || die "required tool not found: $tool"
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rootfs-image.XXXXXX")
ENVROOT=$WORK/env
cleanup() {
    for m in $(awk -v w="$WORK" '$2 ~ "^"w {print $2}' /proc/mounts | sort -r); do
        umount -l "$m" 2>/dev/null || true
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

# Unpack the installer environment
mkdir -p "$ENVROOT"
case "$(head -c4 "$INSTALLIMG" | od -An -tx1 | tr -d ' ')" in
    28b52ffd) DECOMP=(zstd -dc) ;;
    fd377a58) DECOMP=(xz -dc) ;;
    1f8b*)    DECOMP=(gzip -dc) ;;
    *)        DECOMP=(cat) ;;
esac
"${DECOMP[@]}" "$INSTALLIMG" | (cd "$ENVROOT" && cpio -idm --quiet --no-absolute-filenames)

for d in proc sys dev; do
    mkdir -p "$ENVROOT/$d"; mount --rbind "/$d" "$ENVROOT/$d"
done
mkdir -p "$ENVROOT/repo" "$ENVROOT/build-root"
mount --bind "$REPODIR" "$ENVROOT/repo"
mount -o remount,bind,ro "$ENVROOT/repo"
grep -v '^\s*#' "$PKGLIST" | sed 's/#.*//' | tr -s ' \t\n' '\n' | grep -v '^$' > "$ENVROOT/tmp/rootfs-packages"

# Same steps, layout and configuration as host-installer's dnf path
# (backend.mountVolumes, repository.installFromRepos)
chroot "$ENVROOT" /usr/bin/env -i HOME=/root LANG=C.UTF-8 PATH=/usr/sbin:/usr/bin:/sbin:/bin /bin/bash -s <<'INNER'
set -euo pipefail
R=/build-root
for d in proc sys dev; do mkdir -p $R/$d; mount --rbind /$d $R/$d; done
mkdir -p $R/tmp $R/boot/efi $R/var/log
mount -t tmpfs none $R/tmp

# MainYumRepository.disableInitrdCreation()
mkdir -p $R/etc/dracut.conf.d
printf 'echo Skipping initrd creation during host installation\nexit 0\n' > $R/etc/dracut.conf.d/xs_disable.conf

cat > /tmp/yum.conf <<'EOF'
[main]
cachedir=/var/cache/yum/installer
keepcache=0
debuglevel=2
logfile=/var/log/yum.log
exactarch=1
obsoletes=1
gpgcheck=0
plugins=0
installonlypkgs=
distroverpkg=xenserver-release
reposdir=/tmp/repos
history_record=false
install_weak_deps=False

[xcp:main]
name=xcp:main
baseurl=file:///repo
EOF
dnf --releasever=/ --config=/tmp/yum.conf --installroot $R install -y $(cat /tmp/rootfs-packages)
# same second run as host-installer
dnf --releasever=/ --config=/tmp/yum.conf --installroot $R install -y crypto-policies

rm -f $R/etc/dracut.conf.d/xs_disable.conf
rm -rf $R/var/cache/yum/installer

# Scriptlets depending on the *running* kernel (e.g. xcp-ng-release-config's
# bare `depmod -a`) acted on the build host's kernel: redo for the image's.
for k in $R/lib/modules/*/; do chroot $R depmod -a "$(basename $k)"; done
# Per-host state that must not be shared by every host installed from the image
rm -f $R/var/lib/systemd/random-seed

# Generic fallback initrd: no-hostonly plus every ethernet driver. host-installer
# uses it instead of running dracut when the marker matches the installed kernel.
KVER=$(rpm --root $R -q --provides kernel | sed -n 's/^kernel-uname-r = //p' | head -1)
NETMODS=$(find $R/lib/modules/$KVER/kernel/drivers/net/ethernet -name '*.ko*' -printf '%f\n' | sed 's/\.ko.*//' | sort -u | tr '\n' ' ')
chroot $R dracut --no-hostonly --add-drivers "virtio_net $NETMODS" /boot/initrd-fallback.img $KVER
mkdir -p $R/usr/lib/xcp-ng-rootfs-image
echo "$KVER" > $R/usr/lib/xcp-ng-rootfs-image/initrd-fallback.kver

umount $R/tmp
for d in proc sys dev; do umount -R -l $R/$d; done
rpm --root $R -qa --qf '%{NAME}-%{EPOCH}:%{VERSION}-%{RELEASE}.%{ARCH}\n' | sed 's/-(none):/-0:/' | sort > $R/usr/share/xcp-ng-rootfs-image.manifest
echo "rootfs image: $(wc -l < $R/usr/share/xcp-ng-rootfs-image.manifest) packages"
INNER

# zstd decompression speed does not depend on the level: favour size.
# Numeric ownership; host SELinux labels are not part of the image.
tar -C "$ENVROOT/build-root" --numeric-owner --sort=name --acls --xattrs --xattrs-include='*' \
    --xattrs-exclude=security.selinux -cf - . | zstd -19 -T0 -q > "$OUTPUT"
ls -l "$OUTPUT"
