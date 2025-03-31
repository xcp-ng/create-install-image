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
sudo yum install -y genisoimage syslinux grub-tools createrepo_c libfaketime
sudo yum install -y --enablerepo=epel gnupg1
```

## Overview of the generation process

The sequence of steps is:
- `mirror`: (optionally) create a (partial) *local mirror* from
  *source repos*, using [`mirror-repos.sh`](#scriptscreate-isosh)
- `installimg`: create *installer root filesystem* from the *local
  mirror* or from *source repos*, using
  [`./scripts/create-installimg.sh`](#scriptscreate-installimgsh)
- `iso`: create XCP-ng *installation ISO*, from *installer root
  filesystem*, from *local mirror* or *source repos*, and (optionally)
  from a *signing script*, using
  [`./scripts/create-iso.sh`](#scriptscreate-isosh)

## Individual scripts

All script have a `--help` documenting all their options.

### `./scripts/create-iso.sh`

Creates `.iso` from:
- `install.img` (see below)
- yum repository for the product (or a local mirror) for boot files and
  local repository
- additional files from `./iso/$RELEASE/`
- optional signing script

When generating a full image (as opposed to a netinstall one), the yum
repository included in the ISO can optionally be signed.  Since the
signing key is precious and secret material, it is advised not to be
stored on a development machine.  To perform the signing operation,
you have to provide an executable script which will take as parameter
the path to the directory with which contents the ISO will be built.

The script must:
- sign the `repomd.xml` yum repository metadata index using a gpg1
  detached ascii/armor signature
- export the public key usable for signature verification to a
  `RPM-GPG-KEY-*` file at the root of the ISO directory
- set the `[keys]key1` field in `.treeinfo` at the root of the ISO
  directory to name the file created at previous step containing the
  public key

> [!NOTE]
>
> The `scripts/sample-sign-script.sh` example script is only suitable
> for playing with a test key.  A safer solution would for example
> request signature from a signature server, prompting you for an OTP
> token to make sure you're entitled to use the service.

### `./scripts/create-installimg.sh`

Creates `install-$RELEASE.img` for input to `create-iso`, from:
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
- a few large RPMs only useful as build dependencies: ocaml, golang,
  java

Repositories to mirror can be specified in 2 ways:

* a XCP-ng version identifier: the relevant subdirectory of
  https://updates.xcp-ng.org/ will be mirrored under a subdirectory of
  the target directory named after the version.  Eg. this will
  synchronize the official XCP-ng distribution site to
  `~/mirrors/xcpng/8.3/`:
  ```
  ./scripts/mirror-repos.sh 8.3 ~/mirrors/xcpng/
  ```
* a URL to a browsable directory: the whole tree behind this directory
  will be mirrored under a subdirectory of the target directory named
  after the version.  Eg. the above is equivalent to:
  ```
  ./scripts/mirror-repos.sh https://updates.xcp-ng.org/8/8.3 ~/mirrors/xcpng/
  ```

> [!NOTE]
>
> this includes much more packages (order of a few gigabytes) than
> needed for producing the install ISO, notably build-dependencies
> that are not needed by the installer, and not get installed
> themselves on the XCP-ng host either.  But a local mirror which you
> control will provide image reproducibility, through the ability to
> work offline (including reproducibility when the *source repo*
> changes between 2 runs, and consistency when it changes between the
> `installimg` and `iso` steps).

> [!NOTE]
>
> this is not a general-purpose mirroring tool.  It will notably not
> mirror a number of development packages, which you would need to
> build extra software or rebuild packages for XCP-ng.  If you need
> more, use other tools like yum's `reposync` (which sadly we could
> not build on, due to its complete lack of filtering features).

> [!WARNING]
>
> If the script fails with the error message `"Cannot assign requested address"`,
> you need to configure `lftp` DNS resolution order to first look for IPv4
> addresses by adding this line to `~/.lftprc`:
> ```
> set dns:order "inet inet6"
> ```

## Configuration layers and package repositories

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

* The "repo" layers (e.g. `updates`) each provide:
  - `yum-repos.conf.tmpl`, a yum repo configuration template
  - optional `INCLUDE` file to pull additional base repo layers.  The
    `base` layer contains a few extra files, and needs always be in
    the include chain.

Template files will be expanded by string substitution of
`@@KEYWORD@@` patterns.  Some of them are for the scripts' internal
use to fulfill tools requirements, a few of them are user-tunable,
notably the `@@SRCURL@@` one, controlled by the `--srcurl` and
`--srcurl:<overlay>` command-line flags.

Other recognized config files:

* All layers may provide `installer-bootargs.lst`, whose contents will
  be added as installer's dom0 boot parameters.  This is notably
  useful for downstream users to pass `no-gpgcheck` using their own
  layer when building a 8.3 ISO, so they can sign their repo metadata
  with their own key without getting `gpgcheck` refuse to install RPMs
  signed by XCP-ng key.  `repo-gpgcheck` is already effective to
  verify the repo metadata so `gpgcheck` does no provide any real
  value here.  In 8.2 however this option does not exist (only the
  answerfile allows to disable gpg checking, and does not separate
  checking RPMs from repodata).

XCP-ng official repositories are located at
https://updates.xcp-ng.org/ and most of them are available through
standard "repo" layers; e.g. the `testing` repository for `8.2` LTS can
be used as `8.2:testing`.

Custom repositories can be added with `--define-repo` flag (can be
used multiple times to define more than one custom repo).  They will
be used by `yum` using the first `CUSTOMREPO.tmpl` template found in
the layer search path (one is provided in `base`).

## Examples

### 8.3 updates and testing

```
./scripts/mirror-repos.sh 8.3 ~/mirrors/xcpng

sudo ./scripts/create-installimg.sh \
    --srcurl file://$HOME/mirrors/xcpng/8.3 \
    --output install-8.3.testing.img \
    8.3:testing

./scripts/create-iso.sh \
    --srcurl file://$HOME/mirrors/xcpng/8.3 \
    --output xcp-ng-8.3.testing.iso \
    -V "XCP-NG_830_TEST" \
    8.3:testing install-8.3.testing.img
```

### 8.3 updates and linstor

The standalone linstor ISO requires extra packages from a separate
repository.

```
./scripts/mirror-repos.sh 8.3 ~/mirrors/xcpng
./scripts/mirror-repos.sh https://repo.vates.tech/xcp-ng/8/8.3 ~/mirrors/xcpng-rvt/8.3

sudo ./scripts/create-installimg.sh \
    --srcurl file://$HOME/mirrors/xcpng/8.3 \
    --output install-8.3.img \
    8.3:updates

./scripts/create-iso.sh \
    --srcurl file://$HOME/mirrors/xcpng/8.3 \
    --srcurl:linstor file://$HOME/mirrors/xcpng-rvt/8.3 \
    --output xcp-ng-8.3.linstor.iso \
    --extra-packages "xcp-ng-linstor" \
    -V "XCP-NG_830_TEST" \
    8.3:updates:linstor install-8.3.img
```

> [!NOTE]
>
> This example only pulls the latest version of the LINSTOR packages.
> To be suitable for update of a LINSTOR-enabled XCP-ng 8.2.1, it must
> *also* be provided with the version matching the 8.2.1 installation.


### tip of 8.2 (8.2 + updates)

```
./scripts/mirror-repos.sh 8.2 ~/mirrors/xcpng

sudo ./scripts/create-installimg.sh \
    --srcurl file://$HOME/mirrors/xcpng/8.2 \
    --output install-8.2.updates.img \
    8.2:updates

./scripts/create-iso.sh \
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

## Testing that scripts run correctly

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
