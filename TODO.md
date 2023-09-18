# TODO list for ISO creation scripts

* [ ] multipath support ?
    - [ ] /etc/udev/rules.d/40-multipath.rules
* [ ] extract `.treeinfo` data from branding
* [ ] let `--define-repo` also take a gpg-key
* [ ] disable more services
    - [ ] ldconfig.service xenstored.service etc. links to /dev/null (those two at least seem
          unneeded)
    - [ ] /etc/udev/rules.d/: 11-dm-mpath.rules 62-multipath.rules 69-dm-lvm-metad.rules links to /dev/null
* [ ] improved key handling
  * allow using a separately-generated-and-signed repository
  * missing in installed system
    - [ ] Citrix rpm keys (driver disks? sup packs?)
* possible additional cleanups
  * still some packages to be cleaned up
    - [ ] limit firwmare to that useable by provided drivers
    - [ ] /var/cache
