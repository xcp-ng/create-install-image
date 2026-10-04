#!/usr/bin/env python3
"""Boot an installed disk from a bench run, log in on the serial console and
check that the host is functional. Usage: firstboot-check.py <run-dir> [grub-entry-index]
Writes <run-dir>/firstboot-<entry>.log (console) and firstboot-<entry>.txt (command outputs)."""
import os, re, socket, subprocess, sys, time

run = os.path.realpath(sys.argv[1])
entry = int(sys.argv[2]) if len(sys.argv) > 2 else None
tag = 'default' if entry is None else 'entry%d' % entry
sock_path = os.path.join(run, 'fb-serial.sock')
console = open(os.path.join(run, 'firstboot-%s.log' % tag), 'wb')
report = open(os.path.join(run, 'firstboot-%s.txt' % tag), 'w')
if os.path.exists(sock_path):
    os.unlink(sock_path)

qemu = subprocess.Popen([
    'qemu-system-x86_64', '-machine', 'q35,accel=kvm', '-cpu', 'host', '-smp', '4', '-m', '8192',
    '-drive', 'if=pflash,format=raw,readonly=on,file=%s' % os.environ.get('OVMF_CODE', '/usr/share/edk2/ovmf/OVMF_CODE.fd'),
    '-drive', 'if=pflash,format=raw,file=%s/vars.fd' % run,
    '-drive', 'file=%s/disk.img,format=raw,if=virtio,cache=none,aio=native' % run,
    '-netdev', 'user,id=n0', '-device', 'virtio-net-pci,netdev=n0,mac=52:54:00:12:34:56',
    '-display', 'none', '-serial', 'unix:%s,server=on,wait=on' % sock_path, '-no-reboot'])
while not os.path.exists(sock_path):
    time.sleep(0.1)
s = socket.socket(socket.AF_UNIX); s.connect(sock_path); s.settimeout(1)
buf = b''
start = time.time()

def expect(pattern, timeout):
    global buf
    deadline = time.time() + timeout
    rx = re.compile(pattern.encode())
    while time.time() < deadline:
        m = rx.search(buf)
        if m:
            out = buf[:m.end()]; buf = buf[m.end():]
            return out
        try:
            data = s.recv(65536)
        except socket.timeout:
            continue
        if not data:
            break
        console.write(data); console.flush()
        buf += data
    raise TimeoutError("timeout waiting for %r after %.0fs" % (pattern, time.time() - start))

def send(text):
    # Xen may switch the UART to polling mode, which drops input bursts: pace keystrokes
    for ch in text.encode():
        s.sendall(bytes([ch]))
        time.sleep(0.004)

def run_cmd(cmd, timeout=120):
    marker = '__END_%d__' % int(time.time() * 1000)
    send("%s; echo %s $?\r" % (cmd, marker))
    out = expect(r'(?<!echo )%s (\d+)' % marker, timeout).decode(errors='replace')
    out = out.replace('\r', '')
    body = out
    body = body.rsplit(marker, 1)[0]
    rc = re.search(r'%s (\d+)' % marker, out)
    report.write("### %s\n%s\n" % (cmd, body.strip()))
    report.flush()
    return body

try:
    if entry is not None:
        expect(r'Use the .* keys', 60)
        time.sleep(0.5)
        send('\x1b[B' * (entry - 1))     # default is entry 1 ("XCP-ng (Serial)")
        time.sleep(0.5)
        send('\r')
    expect(r'login: ', 600)
    report.write("login prompt after %.0fs\n" % (time.time() - start))
    send('root\r'); expect(r'Password: ', 30); send('xcpngbench\r')
    expect(r'\]# ', 60)
    send("bind 'set enable-bracketed-paste off'; export PS1='# '; stty cols 200 -echo; export SYSTEMD_PAGER=\r")
    expect(r'SYSTEMD_PAGER=[\s\S]*?# ', 10)
    run_cmd('uname -r; cat /proc/cmdline; xl info xen_commandline 2>/dev/null; lsinitrd -s 2>/dev/null | head -0')
    run_cmd('timeout 300 systemctl is-system-running --wait', 330)
    run_cmd('systemctl --failed --no-legend --plain')
    run_cmd('for i in $(seq 120); do xe host-list --minimal >/dev/null 2>&1 && break; sleep 2; done; '
            'xe host-list params=name-label,enabled,software-version --minimal', 300)
    run_cmd('xe sr-list params=name-label,type,physical-size --minimal; '
            'xe pif-list params=device,IP-configuration-mode,management --minimal')
    if not os.environ.get('QUICK'):
        run_cmd('rpm -qa | wc -l; rpm -Va --nomtime 2>&1 | sort', 600)
        run_cmd('getcap -r /usr 2>/dev/null | sort')
        run_cmd('lsinitrd /boot/initrd-fallback.img 2>/dev/null | grep -c "\\.ko"; ls -la /boot/initrd*')
    for c in filter(None, os.environ.get('EXTRA_CMDS', '').split(';;')):
        run_cmd(c, 300)
    report.write("checks done after %.0fs\n" % (time.time() - start))
    send('poweroff\r')
    qemu.wait(timeout=120)
except Exception as e:
    report.write("FAILED: %s\n" % e)
    qemu.kill()
    sys.exit(1)
finally:
    report.close(); console.close()
