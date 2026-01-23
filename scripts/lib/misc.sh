# consistent erroring out

die() {
    echo >&2
    echo >&2 "ERROR: $*"
    echo >&2
    exit 1
}

# usage() is script-specific, implement it yourself

die_usage() {
    usage >&2
    die "$*"
}


# populates CFG_SEARCH_PATH array
parse_config_search_path() {
    CFG_SEARCH_PATH=()
    _parse_config_search_path "$1"
}

_parse_config_search_path() {
    local pathstr="$1"
    while true; do
        local dir=${pathstr%%:*}
        local absdir
        case "$dir" in
            /*) absdir="$dir" ;;
            *) absdir=$(realpath "$topdir/configs/$dir") ;;
        esac
        [ -d "$absdir" ] || die "directory not found: $absdir"
        CFG_SEARCH_PATH+=("$absdir")

        if [ -r "$absdir/INCLUDE" ]; then
            while read include; do
                _parse_config_search_path "$include"
            done < "$absdir/INCLUDE"
        fi

        [ "$pathstr" != "$dir" ] || break # was last component in search path
        pathstr=${pathstr#${dir}:}        # strip this dir and loop
    done
}

find_config() {
    local filename="$1"
    for dir in "${CFG_SEARCH_PATH[@]}"; do
        try="$dir/$filename"
        if [ -r "$try" ]; then
            echo "$try"
            return
        fi
    done
    die "cannot find '$filename' in ${CFG_SEARCH_PATH[*]}"
}

find_all_configs() {
    local filename="$1"
    for dir in "${CFG_SEARCH_PATH[@]}"; do
        try="$dir/$filename"
        if [ -r "$try" ]; then
            echo "$try"
        fi
    done
}

# default src URL depending on selected $DIST

SRCURL=
declare -A SRCURLS=()


# cleanup tempfiles on exit

CLEANUP_DIRS=()
CLEANUP_FILES=()
exitcleanup() {
    local exitcode=$?
    rm -rf "${CLEANUP_DIRS[@]}"
    rm -f "${CLEANUP_FILES[@]}"

    [ $exitcode = 0 ] || echo >&2 "An ERROR happenned"
}
trap 'exitcleanup' EXIT INT


# Avoid yum keeping a cache in /var/tmp with a temporary name but
# getting reused between runs, and confusing yum about which rpm
# versions should be available.  Yeah that sucks hard.
# See https://unix.stackexchange.com/questions/92257/
export TMPDIR=$(mktemp -d "$PWD/tmpdir-XXXXXX")
CLEANUP_DIRS+=("$TMPDIR")


# infrastructure for fetching RPMs from source repo

yumdl_is_dnf() {
    if command -v yumdownloader >/dev/null; then
        yumdownloader --version | grep -q dnf
    else
        # assume we're using dnf without a yumdownloader wrapper
        true
    fi
}

if [ "$PKGTOOL" = "yum" ] && yumdl_is_dnf; then
    die "this 'yum' is a wrapper around 'dnf', maybe you meat '--pkgtool dnf'"
fi

setup_yum_download() {
    [ $# = 2 ] || die "setup_yum_download: need exactly 2 arguments"
    DIST="$1"
    RPMARCH="$2"

    YUMDLCONF_TMPL=$(find_config yumdl.conf.tmpl)

    YUMDLCONF=$(mktemp "$TMPDIR/yum-XXXXXX.conf")
    YUMREPOSD=$(mktemp -d "$TMPDIR/yum-repos-XXXXXX.d")
    YUMLOGDIR=$(mktemp -d "$TMPDIR/logs-XXXXXX")
    DUMMYROOT=$(mktemp -d "$TMPDIR/root-XXXXXX")

    case "$PKGTOOL" in
        dnf)
            enable_plugins=1
            echo >&2 "WARNING: dnf download is a plugin, I have to enable dnf plugins!"
            ;;
        yum)
            enable_plugins=0
            ;;
        *) die "unsupported pkgtool '$PKGTOOL'" ;;
    esac

    cat "$YUMDLCONF_TMPL" |
        sed \
            -e "s,@@ENABLE_PLUGINS@@,$enable_plugins," \
            -e "s,@@YUMREPOSD@@,$YUMREPOSD," \
            -e "s,@@CACHEDIR@@,$TMPDIR/yum-cache," \
            -e "s,@@RPMARCH@@,$RPMARCH," \
            > "$YUMDLCONF"
    [ -z "$VERBOSE" ] || cat "$YUMDLCONF"
    mkdir ${VERBOSE} "$DUMMYROOT/etc"
    YUMDLFLAGS=(
        # non-$VERBOSE is -q, $VERBOSE is default, yum's -v would be debug
        $([ -n "$VERBOSE" ] || printf -- "-q")
        --config="$YUMDLCONF"
        --releasever="$DIST"
    )

    setup_yum_repos "${YUMDLFLAGS[@]}"
}

setup_yum_repos() {
    # repos declated in yum-repos.conf.tmpl
    find_all_configs yum-repos.conf.tmpl | while read YUMREPOSCONF_TMPL; do
        OVLDIR=$(dirname "$YUMREPOSCONF_TMPL")
        reponame=$(basename "$OVLDIR")
        OVL_SRCURL=${SRCURLS[$reponame]:-$SRCURL}
        if [ -z "$OVL_SRCURL" -a -e "$OVLDIR/DEFAULT_SRCURL" ]; then
            OVL_SRCURL=$(cat "$OVLDIR/DEFAULT_SRCURL")
        fi
        cat "$YUMREPOSCONF_TMPL" |
            sed \
                -e "s,@@SRCURL@@,${OVL_SRCURL}," \
                -e "s,@@RPMARCH@@,$RPMARCH," \
                > "$YUMREPOSD/$reponame.repo"
    done

    # custom repos from cmdline
    if [ "${#CUSTOM_REPOS[@]}" -gt 0 ]; then
        CUSTOMREPO_TEMPLATE=$(find_config CUSTOMREPO.tmpl)
        for repoid in "${!CUSTOM_REPOS[@]}"; do
            repourl="${CUSTOM_REPOS[$repoid]}"
            cat "$CUSTOMREPO_TEMPLATE" |
                sed \
                    -e "s,@@REPOID@@,$repoid," \
                    -e "s,@@REPOURL@@,$repourl," \
                    -e "s,@@RPMARCH@@,$RPMARCH," \
                    > "$YUMREPOSD/$repoid.repo"
        done
    fi

    # summary of repos
    # FIXME: update for DNF?
    test ! -r /var/cache/yum/xcpng-base || die "yum system cache should not be there to start with"
    [ -z "$VERBOSE" ] || ls "$YUMREPOSD"
    "$PKGTOOL" "$@" repolist all --verbose
    # double-check we don't let yum reintroduce that cache by mistake
    test ! -r /var/cache/yum/xcpng-base || die "yum system cache should not have been created"
}

get_rpms() {
    local OPTS=""
    if [ "$1" = "--depends" ]; then
        OPTS="--resolve"
        shift
    fi
    local DESTDIR="$1"
    shift
    if [ -n "$YUMDLFLAGS" ]; then
        (cd "$DESTDIR" && "${DLTOOL[@]}" $OPTS "${YUMDLFLAGS[@]}" --installroot="$DUMMYROOT" "$@")
    else
        die "Must configure yum download before attempting to download"
    fi
}
