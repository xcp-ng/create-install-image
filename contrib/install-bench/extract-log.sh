#!/bin/bash
# Usage: extract-log.sh <run-dir> -> copies installer logs (from the 'logs' partition) and rpm -qa (from root)
set -euo pipefail
W=$1; mkdir -p "$W/logs"
part() { sfdisk -J "$W/disk.img" | python3 -c "import json,sys; print([p['start'] for p in json.load(sys.stdin)['partitiontable']['partitions'] if p.get('name')=='$1'][0])"; }
L="$W/disk.img?offset=$(( $(part logs) * 512 ))"
R="$W/disk.img?offset=$(( $(part root) * 512 ))"
debugfs -R "cat /installer/install-log" "$L" > "$W/logs/install-log" 2>/dev/null
debugfs -R "cat /installer/rpm-qa-log" "$L" > "$W/logs/rpm-qa-installer" 2>/dev/null || true
mkdir -p "$W/rpmdb"; debugfs -R "dump /usr/lib/sysimage/rpm/rpmdb.sqlite $W/rpmdb/rpmdb.sqlite" "$R" 2>/dev/null
rpm --dbpath "$(realpath "$W/rpmdb")" -qa --qf '%{NAME}\n' 2>/dev/null | sort > "$W/logs/packages.txt"
echo "$(wc -l < "$W/logs/install-log") log lines, $(wc -l < "$W/logs/packages.txt") packages installed"
