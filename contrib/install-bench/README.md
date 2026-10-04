# Install benchmark and first-boot check (DEMONSTRATOR)

Tools used to measure and validate the XCP-ng 9 install speedup. They run on a
Linux workstation with KVM, QEMU and OVMF (paths default to Fedora's).

## Time an install

```
./run-bench.sh <iso> <run-dir> [<overlay-dir>...]
./extract-log.sh <run-dir>              # installer log + package list from the installed disk
python3 analyze.py <run-dir>/logs/install-log   # time per installer task
```

`run-bench.sh` boots the ISO's own GRUB, Xen, kernel and `install.img` from a
small ESP disk, with `answerfile.xml` appended to `install.img`, installs to a
sparse 64 GB virtio disk, and prints `TOTAL` from QEMU start to the reboot that
ends the install. Overlay directories are appended to `install.img` too, e.g. a
patched `opt/xensource/installer` to test installer changes without rebuilding
the ISO.

`overlay/` adds a unit that copies the installer's task lines to the serial
console (`<run-dir>/serial.raw`). Do not stream the full install log there:
at 115200 baud it slows the install down considerably.

## Check the installed host

```
python3 firstboot-check.py <run-dir> [<grub-entry-index>]
```

Boots the installed disk, logs in on the serial console (root password from
`answerfile.xml`) and records boot time to login, failed units, XAPI hosts,
SRs and PIFs, `rpm -Va`, file capabilities and the fallback initrd into
`<run-dir>/firstboot-*.txt`. `QUICK=1` skips the slow `rpm -Va`;
`EXTRA_CMDS="cmd1;;cmd2"` runs more commands. Compare two runs (stock ISO vs
modified ISO) with `diff` on those outputs.

Notes:
- First-boot services such as `storage-init` start late; the check powers the
  VM off at the end, which can interrupt them. Let them finish before comparing
  SRs (see `EXTRA_CMDS`).
- Xen can switch the emulated UART to polling mode; input is paced to avoid
  losing characters.
- Run-to-run noise on a workstation is about ±3 s.
