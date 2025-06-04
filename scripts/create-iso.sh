#! /bin/bash
set -eE
set -o pipefail

mydir=$(dirname $0)
topdir=$mydir/..

. "$mydir/lib/misc.sh"

[ "$(id -u)" != 0 ] || die "should not run as root"

usage() {
    cat <<EOF
Usage: $0 [<options>] <base-config>[:<config-overlay>]* <install.img>

Options:
    -o|--output <output-iso>  (mandatory) output filename
    -V <VOLID>                (mandatory) ISO volume ID
    --srcurl <URL>            get RPMs from base-config and overlays from <URL>
                              default: https://updates.xcp-ng.org/<MAJOR>/<DIST>
    --srcurl:<OVERLAY> <URL>  get RPMs for specified <OVERLAY> from <URL>
                              default: the global <URL> controled by --srcurl
    -D|--define-repo <NICK>!<URL>
                              add yum repo with name <NICK> and base URL <URL>
    --extra-packages "<PACKAGE> [<PACKAGE> ...]"
                              include packages and their dependencies in repo
    --efi-installer <mode>    select how to build the GRUB EFI binary. Valid modes:
                              rpm: take prebuilt xenserver/grubx64.efi from rpm
                              mkimage: call mkimage to generate an EFI binary
    --netinstall              do not include repository in ISO
    --sign-script <SCRIPT>    sign repomd using <SCRIPT>
    --force-overwrite         don't abort if output file already exists
    --verbose                 be talkative
EOF
}

VERBOSE=
OUTISO=
FORCE_OVERWRITE=0
DOREPO=1
SIGNSCRIPT=
EXTRA_PACKAGES=
declare -A CUSTOM_REPOS=()
RPMARCH="x86_64"
EFIMODE="rpm"
while [ $# -ge 1 ]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --verbose|-v)
            VERBOSE=-v
            ;;
        --output|-o)
            [ $# -ge 2 ] || die_usage "$1 needs an argument"
            OUTISO="$2"
            shift
            ;;
        --force-overwrite)
            FORCE_OVERWRITE=1
            ;;
        -V)
            [ $# -ge 2 ] || die_usage "$1 needs an argument"
            VOLID="$2"
            shift
            ;;
        --netinstall)
            DOREPO=0
            ;;
        --srcurl)
            [ $# -ge 2 ] || die_usage "$1 needs an argument"
            SRCURL="$2"
            shift
            ;;
        --srcurl:*)
            [ $# -ge 2 ] || die_usage "$1 needs an argument"
            OVL="${1#--srcurl:}"
            [ -n "$OVL" -a -d "$topdir/configs/$OVL" ] || die_usage "$1 does not name an existing overlay"
            SRCURLS["$OVL"]="$2"
            shift
            ;;
        -D|--define-repo)
            [ $# -ge 2 ] || die_usage "$1 needs an argument"
            case "$2" in
                *!*)
                    nick="${2%!*}"
                    url="${2#*!}"
                    ;;
                *)
                    die "$1 argument must have 2 parts separated by a '!'"
                    ;;
            esac
            CUSTOM_REPOS["$nick"]="$url"
            shift
            ;;
        --extra-packages)
            [ $# -ge 2 ] || die_usage "$1 needs an argument"
            EXTRA_PACKAGES="$2"
            shift
            ;;
        --efi-installer)
            [ $# -ge 2 ] || die_usage "$1 needs an argument"
            case "$2" in
                rpm|mkimage) EFIMODE="$2" ;;
                *) die "unknown --efi-installer '$2'" ;;
            esac
            shift
            ;;
        --sign-script)
            [ $# -ge 2 ] || die_usage "$1 needs an argument"
            SIGNSCRIPT="$2"
            shift
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

[ $# = 2 ] || die_usage "need exactly 2 non-option arguments"
[ -n "$VOLID" ] || die_usage "volume ID must be specified (-V)"
[ -n "$OUTISO" ] || die_usage "output filename must be specified (--output)"
if [ "$FORCE_OVERWRITE" = 0 -a -e "$OUTISO" ]; then
    die "'$OUTISO' exists, use --force-overwrite to proceed regardless"
fi
[ ! -d "$OUTISO" ] || die "'$OUTISO' exists and is a directory"

if [ $DOREPO = 0 -a -n "$SIGNSCRIPT" ]; then
    die_usage "signing script is useless on netinstall media"
fi

parse_config_search_path "$1"
DIST="$(basename ${CFG_SEARCH_PATH[0]})"
INSTALLIMG="$2"

[ -z "$VERBOSE" ] || set -x

maybe_set_srcurl "$DIST"
test -r "$INSTALLIMG" || die "cannot read '$INSTALLIMG' for install.img"

command -v genisoimage >/dev/null || die "required tool not found: genisoimage"
command -v isohybrid >/dev/null || die "required tool not found: isohybrid (syslinux)"
command -v createrepo_c >/dev/null || die "required tool not found: createrepo_c"

MKIMAGE=$(command -v grub2-mkimage || command -v grub-mkimage) || die "could not find grub[2]-mkimage"
if [[ "$($MKIMAGE --version)" =~ ".*2.02" ]]; then
    die "$MKIMAGE is too old, make sure to have 2.06 installed (XCP-ng package grub-tools)"
fi

if command -v faketime >/dev/null; then
    FAKETIME=(faketime "2000-01-01 00:00:00")
else
    echo 2>&1 "WARNING: tool not found, disabling support: faketime (libfaketime)"
    FAKETIME=()
fi

ISODIR=$(mktemp -d "$TMPDIR/installiso.XXXXXX")

# temporary for storing downloaded files etc
SCRATCHDIR=$(mktemp -d "$TMPDIR/tmp.XXXXXX")

setup_yum_download "$DIST" "$RPMARCH"


## put all bits together

test -d "$topdir/templates/iso/$DIST" || die "cannot find dir '$topdir/templates/iso/$DIST'"

# bootloader config files etc. - like "cp -r *", not forgetting .treeinfo
tar -C "$topdir/templates/iso/$DIST" -cf - . | tar -C "$ISODIR/" -xf - ${VERBOSE}

# initrd
cp ${VERBOSE} -a "$INSTALLIMG" $ISODIR/install.img

# kernel from rpm
get_rpms "$SCRATCHDIR" kernel
rpm2cpio $SCRATCHDIR/kernel-*.rpm | (cd $ISODIR && cpio ${VERBOSE} -idm "*vmlinuz*")
rm ${VERBOSE} $ISODIR/boot/vmlinuz-*-xen
mv ${VERBOSE} $ISODIR/boot/vmlinuz-* $ISODIR/boot/vmlinuz

# alt kernel from rpm
get_rpms "$SCRATCHDIR" kernel-alt
rpm2cpio $SCRATCHDIR/kernel-alt-*.rpm | (cd $ISODIR && cpio ${VERBOSE} -idm "*vmlinuz*")
rm ${VERBOSE} $ISODIR/boot/vmlinuz-*-xen
mkdir ${VERBOSE} $ISODIR/boot/alt
mv ${VERBOSE} $ISODIR/boot/vmlinuz-* $ISODIR/boot/alt/vmlinuz

# xen from rpm
# Note: we use the debug version of the hypervisor (as does XenServer), to make it
# possible to get a more useful `xl dmesg` if anything goes wrong.
get_rpms "$SCRATCHDIR" xen-hypervisor
rpm2cpio $SCRATCHDIR/xen-hypervisor-*.rpm | (cd $ISODIR && cpio ${VERBOSE} -idm "*xen*gz")
mv ${VERBOSE} $ISODIR/boot/xen-*-d.gz $ISODIR/boot/xen.gz
rm ${VERBOSE} $ISODIR/boot/xen-*.gz


# Memtest86
get_rpms "$SCRATCHDIR" memtest86+
rpm2cpio $SCRATCHDIR/memtest86+-*.rpm | (cd $ISODIR && cpio ${VERBOSE} -idm "./boot/*")
if [ ! -r $ISODIR/boot/memtest.bin ]; then
    # older 5.x packaging
    rm ${VERBOSE} $ISODIR/boot/elf-memtest86+-*
    mv ${VERBOSE} $ISODIR/boot/memtest86+-* $ISODIR/boot/memtest.bin
fi

# branding: EULA, LICENSES
get_rpms "$SCRATCHDIR" branding-xcp-ng
rpm2cpio $SCRATCHDIR/branding-xcp-ng-*.rpm |
    (cd $ISODIR && cpio ${VERBOSE} -idm ./usr/src/branding/EULA ./usr/src/branding/LICENSES)
mv ${VERBOSE} $ISODIR/usr/src/branding/* $ISODIR/
(cd $ISODIR && rmdir -p usr/src/branding/)


# linux boot options

sed_bootloader_configs() {
    sed -i "$@" \
        $ISODIR/boot/isolinux/isolinux.cfg \
        $ISODIR/*/*/grub*.cfg
}

EXTRABOOTPARAMS=$(find_all_configs installer-bootargs.lst | xargs --no-run-if-empty cat)
if [ -n "${EXTRABOOTPARAMS}" ]; then
    sed_bootloader_configs \
        -e "s|/vmlinuz|/vmlinuz ${EXTRABOOTPARAMS}|"
fi


# optional local repo

if [ $DOREPO = 1 ]; then
    rpm2cpio $SCRATCHDIR/branding-xcp-ng-*.rpm |
        (cd $ISODIR && cpio ${VERBOSE} -i --to-stdout ./usr/src/branding/branding) |
        grep -E "^(PLATFORM|PRODUCT)_" > $TMPDIR/branding.sh
    . $TMPDIR/branding.sh

    sed -i \
        -e "s,@@TIMESTAMP@@,$(date +%s.00)," \
        -e "s,@@PLATFORM_NAME@@,$PLATFORM_NAME," \
        -e "s,@@PLATFORM_VERSION@@,$PLATFORM_VERSION," \
        -e "s,@@PRODUCT_BRAND@@,$PRODUCT_BRAND," \
        -e "s,@@PRODUCT_VERSION@@,$PRODUCT_VERSION," \
        $ISODIR/.treeinfo

    mkdir ${VERBOSE} "$ISODIR/Packages"

    get_rpms --depends "$ISODIR/Packages" xcp-ng-deps kernel-alt ${EXTRA_PACKAGES}

    createrepo_c ${VERBOSE} "$ISODIR"
    if [ -n "$SIGNSCRIPT" ]; then
        "$SIGNSCRIPT" "$ISODIR"
        # Check that the digest is strong enough. Value 8 means SHA256.
        # See https://www.rfc-editor.org/rfc/rfc4880#section-9.4
        echo "Checking the strength of the signature (repodata/repomd.xml.asc)"
        gpg --list-packets "$ISODIR"/repodata/repomd.xml.asc |
            awk '/digest algo/ { if ($3 + 0 >= 8 && $3 + 0 <= 11) { print "Valid digest algorithm"; exit 0; } else { print "Invalid digest algorithm"; exit 1; } }'
    else
        # installer checks if keys are here even when verification is disabled
        [ -z "$VERBOSE" ] || echo "disabling keys in .treeinfo"
        sed -i "s,^key,#key," \
            $ISODIR/.treeinfo

        # don't try to validate repo sig if we put none
        [ -z "$VERBOSE" ] || echo "adding no-repo-gpgcheck to boot/isolinux/isolinux.cfg EFI/xenserver/grub*.cfg"
        sed_bootloader_configs \
            -e "s,/vmlinuz,/vmlinuz no-repo-gpgcheck,"
    fi
else # no repo
    # remove unused template
    rm ${VERBOSE} "$ISODIR/.treeinfo"

    # trigger netinstall mode
    sed_bootloader_configs \
        -e "s@/vmlinuz@/vmlinuz netinstall@"
fi


# BIOS bootloader: isolinux from rpm

get_rpms "$SCRATCHDIR" syslinux
mkdir "$SCRATCHDIR/syslinux"
rpm2cpio $SCRATCHDIR/syslinux-*.rpm | (cd "$SCRATCHDIR/syslinux" && cpio ${VERBOSE} -idm "./usr/share/syslinux/*")

cp ${VERBOSE} -p \
   "$SCRATCHDIR/syslinux/usr/share/syslinux/isolinux.bin" \
   "$SCRATCHDIR/syslinux/usr/share/syslinux/mboot.c32" \
   "$SCRATCHDIR/syslinux/usr/share/syslinux/menu.c32" \
   \
   $ISODIR/boot/isolinux/

# files to copy for LegacyBIOS PXE support
# FIXME: location for backward compatibility with XS and XCP-ng-8.2
mkdir "$ISODIR/boot/pxelinux"
cp ${VERBOSE} -p \
   "$SCRATCHDIR/syslinux/usr/share/syslinux/pxelinux.0" \
   "$SCRATCHDIR/syslinux/usr/share/syslinux/mboot.c32" \
   "$SCRATCHDIR/syslinux/usr/share/syslinux/menu.c32" \
   \
   "$ISODIR/boot/pxelinux/"

## create final ISO

# UEFI bootloader
if false; then
    # grub-mkrescue is "the reference", providing largest platform
    # support for booting, but OTOH adds tons of stuff we don't need
    # at all. It was used as a reference to implement UEFI boot, and
    # is kept handy for when we need it, since the command options are
    # not that obvious. Eg. we may want to add support for x86 Macs
    # some day.
    # Note this current invocation seems to miss UEFI boot support for
    # some reason.

    MKRESCUE=$(command -v grub2-mkrescue || command -v grub-mkrescue) || die "could not find grub[2]-mkrescue"
    # grub2-mkrescue (centos) vs. grub-mkrescue (debian, RoW?)
    #strace -f -o /tmp/log -s 4096
    "$MKRESCUE" \
        --locales= \
        --modules= \
        --product-name="XCP-ng" --product-version="$DIST" \
        \
        -v \
        -follow-links \
        -r -J --joliet-long -V "$VOLID" -input-charset utf-8 \
        -c boot/isolinux/boot.cat -b boot/isolinux/isolinux.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        \
        -o "$OUTISO" $ISODIR

else
    # unpack grub-efi.rpm
    get_rpms "$SCRATCHDIR" grub-efi
    mkdir "$SCRATCHDIR/grub"
    rpm2cpio $SCRATCHDIR/grub-efi-*.rpm | (cd "$SCRATCHDIR/grub" && cpio ${VERBOSE} -idm)

    case "$EFIMODE" in
        rpm)
            BOOTX64="$SCRATCHDIR/grub/boot/efi/EFI/xenserver/grubx64.efi"
            ;;
        mkimage)
            BOOTX64=$(mktemp "$TMPDIR/bootx64-XXXXXX.efi")

            "$MKIMAGE" --directory "$SCRATCHDIR/grub/usr/lib/grub/x86_64-efi" --prefix '()/EFI/xenserver' \
                       $VERBOSE \
                       --output "$BOOTX64" \
                       --format 'x86_64-efi' --compression 'auto' \
                       'part_gpt' 'part_msdos' 'part_apple' 'iso9660'

            # grub modules
            # FIXME: too many modules?
            tar -C "$SCRATCHDIR/grub/usr/lib" -cf - grub/x86_64-efi |
                tar -C "$ISODIR/boot" -xf - ${VERBOSE}
            ;;
    esac

    "${FAKETIME[@]}" mformat -i "$ISODIR/boot/efiboot.img" -N 0 -C -f 2880 -L 16 ::.
    # Under faketime on CentOS 7 the last sector gets "random" contents instead of zero.
    # We're not sure why (FIXME?) but make sure that data does not leak or polute.
    dd if=/dev/zero of="$ISODIR/boot/efiboot.img" bs=512 count=1 seek=$((2880*2 - 1))

    "${FAKETIME[@]}" mmd     -i "$ISODIR/boot/efiboot.img" ::/EFI ::/EFI/BOOT
    "${FAKETIME[@]}" mcopy   -i "$ISODIR/boot/efiboot.img" "$BOOTX64" ::/EFI/BOOT/BOOTX64.EFI

    # Seems some BIOSes set this image as root instead of the ISO,
    # need a (slightly modified) grub.cfg to embed inside
    GRUBEFIBOOTCFGPATCH=$(find_config grub-efiboot-cfg.patch)
    cp "$ISODIR/EFI/xenserver/grub.cfg" "$TMPDIR/grub-efiboot.cfg"
    patch $([ -n "$VERBOSE" ] || printf -- "--quiet") "$TMPDIR/grub-efiboot.cfg" "$GRUBEFIBOOTCFGPATCH"
    "${FAKETIME[@]}" mmd     -i "$ISODIR/boot/efiboot.img" ::/EFI/xenserver
    "${FAKETIME[@]}" mcopy   -i "$ISODIR/boot/efiboot.img" "$TMPDIR/grub-efiboot.cfg" ::/EFI/xenserver/grub.cfg


    # files to copy for UEFI PXE support
    # FIXME: location for backward compatibility with XS and XCP-ng-8.2
    cp -p "$BOOTX64" "$ISODIR/EFI/xenserver/"

    genisoimage \
        -o "$OUTISO" \
        ${VERBOSE:- -quiet} \
        -r -J --joliet-long -V "$VOLID" -input-charset utf-8 \
        -c boot/isolinux/boot.cat -b boot/isolinux/isolinux.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        \
        -eltorito-alt-boot --efi-boot boot/efiboot.img \
        -no-emul-boot \
        \
        $ISODIR
    isohybrid ${VERBOSE} --uefi "$OUTISO"
fi

# Local Variables:
# indent-tabs-mode: nil
# End:
