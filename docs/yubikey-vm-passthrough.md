# Yubikey VM passthrough — diagnosis notes

## Symptom

`ykman info` returns "No YubiKey detected" inside the VM, despite the Yubikey
being visible on the USB bus via `lsusb`.

## What was confirmed working

- `lsusb` sees the Yubikey: `Bus 001 Device 005: ID 1050:0407 Yubico YubiKey 5 NFC`
- All three sysfs interface nodes present after proper passthrough:
  - `/sys/bus/usb/devices/1-1:1.0` — HID keyboard
  - `/sys/bus/usb/devices/1-1:1.1` — HID FIDO
  - `/sys/bus/usb/devices/1-1:1.2` — CCID smartcard
- pcscd is correctly configured: the NixOS module sets `PCSCLITE_HP_DROPDIR` to
  `/nix/store/d9ymzvyj06vv1w1125psnwn6a1xjysky-pcscd-plugins` which contains
  `ifd-ccid.bundle`, and passes `-c reader.conf` on the command line.
  The running pcscd binary does respect `PCSCLITE_HP_DROPDIR`.

## Root cause — two independent issues

### Issue 1: incomplete USB passthrough (interfaces missing)

The Yubikey is a USB composite device with three interfaces (HID keyboard, HID
FIDO, CCID). When the libvirt XML specifies the device by vendor/product ID only,
QEMU's xHCI controller passes through only one interface instead of all three.
The guest sees `bNumInterfaces=1` (should be 3) and only the device-level sysfs
node appears — the `1-1:1.*` interface nodes are absent.

Without interface nodes the kernel cannot bind any driver, pcscd gets no udev
events for the CCID interface, and ykman finds nothing.

Fix: detach and re-attach the hostdev in libvirt using a bus/device address
source (`<source>` with bus/device) and `startupPolicy='optional'` rather than
the vendor/product form. This forces QEMU to present the full composite device.

### Issue 2: stale pcscd processes holding the CCID interface

Even after fixing Issue 1, ykman still failed. pcscd logged:

```
Can't claim interface 1/5: LIBUSB_ERROR_BUSY
RFInitializeReader() Open Port 0x200000 Failed
Yubico YubiKey OTP+FIDO+CCID init failed.
```

The CCID interface (`1-1:1.2`) was bound to the `usbfs` driver inside the VM —
indicating that a process already had `/dev/bus/usb/001/005` open. Three stale
pcscd processes from earlier debugging sessions were still running:

```
21897 pcscd -f -d --force-reader-polling
22051 pcscd -f -i
22606 pcscd -f -d
```

Because pcscd is socket-activated, each time ykman or another client connected
to the pcscd socket, systemd started a new pcscd instance — without stopping the
old ones. Each instance tried and failed to claim the CCID interface, leaving
the `usbfs` binding in place.

Fix: kill all stale pcscd processes, which releases the `usbfs` binding on
`1-1:1.2`. The next pcscd invocation (triggered by ykman) succeeds.

## How to reproduce the fix

```bash
# Kill all stale pcscd processes
sudo kill $(pgrep pcscd) 2>/dev/null
sleep 1
# Clean up stale socket files if any
sudo rm -f /run/pcscd/pcscd.comm /run/pcscd/pcscd.pid
# ykman will trigger pcscd via the socket
ykman list
```

## Robust solution — preventing recurrence

### On the VM guest (NixOS)

The stale-process problem is caused by pcscd's `--auto-exit` flag being absent
in the debug invocations, combined with socket activation not stopping old
instances. Two mitigations:

1. **Never run pcscd manually for debugging.** Use `systemctl restart pcscd`
   instead. The systemd unit uses `--auto-exit` (`-x`), which makes pcscd exit
   when no readers are present, keeping the lifecycle clean.

2. **Add to `configuration.nix`** to ensure pcscd is managed exclusively by
   systemd:
   ```nix
   services.pcscd.enable = true;
   ```
   This is already in place; do not run pcscd outside of systemd.

### On the VM host

The libvirt XML for the `experiment` VM already has the correct configuration —
no changes required:

```xml
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source startupPolicy='optional'>
    <vendor id='0x1050'/>
    <product id='0x0407'/>
    <address bus='3' device='5'/>
  </source>
  <alias name='hostdev0'/>
  <address type='usb' bus='0' port='1'/>
</hostdev>
```

Key attributes that make this robust:

- `managed='yes'`: libvirt automatically unbinds host drivers before passthrough
  and rebinds them on VM shutdown. This is what prevents the host from retaining
  driver bindings on the Yubikey interfaces.
- `<vendor id='0x1050'/><product id='0x0407'/>`: device is matched by
  vendor/product, not by bus/device address, so it survives replug and reboot
  without going stale. The `<address bus='3' device='5'/>` inside `<source>` is
  a cached hint added by libvirt after resolving the device — it does not
  override the vendor/product matching.
- `startupPolicy='optional'`: VM starts even if the Yubikey is not plugged in.

The incomplete-passthrough seen earlier (only 1 of 3 interfaces arriving in the
guest) was a transient state caused by detaching/reattaching the device while
stale host driver bindings were present. With `managed='yes'`, libvirt handles
this correctly on a clean attach.
