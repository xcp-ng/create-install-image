# Generation of XCP-ng installation images

The scripts in this repository can be used to generate installation
images for XCP-ng.  The resulting `.iso` images can be burnt on a
CD/DVD or on a USB-storage device.

Two kind of images are currently supported:
* full image, including all necessary packages, allowing installation
  without network access
* "netinstall" image, much smaller, which will only allow packages to
  be fetched from a repository through the network

## General notes

Those scripts should be run in the xcp-ng-build-env docker container
for reproducibility.  Since the base environment is currently based on
CentOS 7, many constraints prevent to make it work properly on more
recent Linux distros.  This base distro is expected to evolve with new
XCP-ng versions.

They require to install some additional packages first:

```
sudo yum install -y genisoimage syslinux grub-tools createrepo_c
sudo yum install -y --enablerepo=epel gnupg1 libfaketime
```


## individual scripts

All script have a `--help` documenting all their options.

### `./scripts/create-install-iso.sh`

Creates `.iso` from:
- `install.img` (see below)
- yum repository for the product (or a local mirror) for boot files and
  local repository
- additional files from `./iso/$RELEASE/`

### `./scripts/create-installimg.sh`

Creates `install-$RELEASE.img` for input to `create-install-iso`, from:
- yum repository for the product (or a local mirror)
- a `packages.lst` file listing RPMs to be installed
- additional files from `./installimg/$RELEASE/`

### `./scripts/mirror-repos.sh`

Note this script requires the `lftp` tool to do its job:

```
sudo yum install -y --enablerepo=epel lftp
```

Creates a local mirror of a subset of an official set of repositories
for a given XCP-ng version, suitable for building an installation ISO.
This scripts excludes from the mirror:
- source RPMs
- development RPMs
- debugging-symbols RPMs

:warning: If the script fails with the error message `"Cannot assign requested address"`,
you need to configure `lftp` DNS resolution order to first look for IPv4
addresses by adding this line to `~/.lftprc`:
```
set dns:order "inet inet6"
```

## configuration layers and package repositories

Configuration layers are defined as a subdirectory of the `configs/`
directory.  Commands are given a layer search path as
`<base-config>[:<config-overlay>]* `.

Standard layers are organized such as two of the standard layers must be
used:

* The "version" layer (e.g. `8.2`) provides required files:
  - `packages.lst` and `yum.conf.tmpl` used to create the `install.img`
    filesystem
  - `yumdl.conf.tmpl` used to download files for the RPM repository
    included in the ISO

* The "repo" layers (e.g. `updates`) each provide a yum repo
  configuration file, and optionally an `INCLUDE` file to pull
  additional base repo layers.  The `base` layer will always be in the
  include chain.

XCP-ng official repositories are located at
https://updates.xcp-ng.org/ and most of them are available through
standard "repo" layers; e.g. the `testing` repository for `8.2` LTS can
be used as `8.2:testing`.

Custom repositories can be added with `--define-repo` flag (can be
used multiple times to define more than one custom repo).  They will
be used by `yum` using the first `CUSTOMREPO.tmpl` template found in
the layer search path (one is provided in `base`).

## examples

### 8.3 updates and testing

```
./scripts/mirror-repos.sh 8.3 ~/mirrors/xcpng

sudo ./scripts/create-installimg.sh \
    --srcurl file://$HOME/mirrors/xcpng/8.3 \
    --output install-8.3.testing.img \
    8.3:testing

./scripts/create-install-iso.sh \
    --srcurl file://$HOME/mirrors/xcpng/8.3 \
    --output xcp-ng-8.3.testing.iso \
    -V "XCP-NG_830_TEST" \
    8.3:testing install-8.3.testing.img
```

### tip of 8.2 (8.2 + updates)

```
./scripts/mirror-repos.sh 8.2 ~/mirrors/xcpng

sudo ./scripts/create-installimg.sh \
    --srcurl file://$HOME/mirrors/xcpng/8.2 \
    --output install-8.2.updates.img \
    8.2:updates

./scripts/create-install-iso.sh \
    --srcurl file://$HOME/mirrors/xcpng/8.2 \
    --output xcp-ng-8.2.updates.iso \
    -V "XCP-NG_82_TEST" \
    8.2:updates install-8.2.updates.img
```

### testing boot modes in qemu

Base command will use PC BIOS:

```
qemu-system-x86_64 -serial stdio -m 2G
```

Note that `-m 1G` is enough to check that the bootloader is properly
loaded and runs, but not to boot to the installer TUI.

For UEFI find the OVMF firmware (on Debian: in `/usr/share/OVMF/`),
and add:

```
 --bios /usr/share/edk2/ovmf/OVMF_CODE.fd
```

(`-net none` was found to be sometimes necessary in UEFI mode, for a
reason still to be determined)

* boot media selection:

  * CD/DVD:
  
  ```
   -cdrom xcp-ng-install.iso
  ```
  
  * USB storage:
  
  ```
   -drive if=none,id=stick,format=raw,file=xcp-ng-install.iso \
   -device nec-usb-xhci,id=xhci \
   -device usb-storage,bus=xhci.0,drive=stick
  ```

## testing that scripts run correctly

Minimal tests to generate install ISO for a few important
configurations are available in `tests/`.  They require one-time
initialization of the `tests/sharness/` submodule:

```
git submodule update --init tests/sharness/
```

They require setting a variable pointing to the repositories to be
used; it is recommended you use a local mirror for this.

Two common ways of running the tests are:

* just using `make`, which produce human-readable
  [TAP](http://testanything.org/) output:

  ```
  make -C tests/ XCPTEST_REPOROOT=file:///data/mirrors/xcpng
  ```

* through `prove` (in package `perl-Test-Harness` in
  CentOS/Fedora/RHEL, in `perl` for the rest of the world), which
  provides both options for e.g. parallel running, and global summary:

  ```
  XCPTEST_REPOROOT=file:///data/mirrors/xcpng prove tests/
  ```

The tests for producing `install.img` are tagged as expensive and not
run by default, to run them you must pass the `-l` flag to the test
script, which can be achieved respectively by:

```
make TEST_OPTS="-l"

prove tests/ :: -l
```
