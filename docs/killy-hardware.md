# Killy hardware configuration

Surveyed from the live installer ISO (NixOS 25.05 Warbler, kernel 6.12.63)
on 2026-03-08.

---

## Motherboard

| Field | Value |
|---|---|
| Manufacturer | ASUSTeK COMPUTER INC. |
| Model | ROG STRIX Z390-I GAMING |
| Chipset | Intel Z390 (Cannon Lake PCH) |
| Form factor | Mini-ITX |
| BIOS | American Megatrends, version 3006, released 2021-10-12 |
| Max RAM capacity | 64 GB (2 DIMM slots, up to 32 GB per slot) |

## CPU

| Field | Value |
|---|---|
| Model | Intel Core i9-9900K (Coffee Lake, 9th gen) |
| Cores / threads | 8 cores, 16 threads |
| Base clock | 3.60 GHz |
| L1d cache | 256 KiB (8 × 32 KiB) |
| L1i cache | 256 KiB (8 × 32 KiB) |
| L2 cache | 2 MiB (8 × 256 KiB) |
| L3 cache | 16 MiB (shared) |
| Integrated GPU | Intel UHD Graphics 630 |

## Memory

32 GiB total — 2 × 16 GiB DDR4 DIMMs (both slots populated):

| Slot | Size | Type | Speed | Part number |
|---|---|---|---|---|
| ChannelA-DIMM0 | 16 GB | DDR4 | 2133 MT/s | Corsair CMK32GX4M2A2400C14 |
| ChannelB-DIMM0 | 16 GB | DDR4 | 2133 MT/s | Corsair CMK32GX4M2A2400C14 |

Rated at 2400 MT/s (XMP), running at 2133 MT/s (JEDEC default — XMP profile
not enabled in BIOS). Both slots are populated; reaching 64 GiB requires
replacing both DIMMs with 32 GB sticks.

## Storage

Two NVMe SSDs on PCIe (Intel SSD DC P4101/Pro 7600p series):

| Device | Model | Capacity | Power-on hours | Health |
|---|---|---|---|---|
| `/dev/nvme0n1` | INTEL SSDPEKKW512G8 | 512 GB | 14,218 h | 0% used |
| `/dev/nvme1n1` | INTEL SSDPEKKW020T8 | 2 TB | 9,524 h | 0% used |

Both drives report 0% percentage used (wear indicator) — effectively new.
Temperatures at survey time: 45 °C (nvme0) and 49 °C (nvme1), both normal.

Current partitioning (from installer USB boot):
- `nvme0n1p1` 511 MiB — existing EFI partition
- `nvme0n1p2` 476 GiB — existing Linux partition
- `nvme1n1p1` 1.9 TiB — single partition

The installer ISO is booted from a Lexar USB flash drive (`/dev/sda`, 57.6 GiB).

**Recommended disk layout for NixOS install (spec 0005):** install the OS on
`nvme0n1` (512 GB, faster, lower hours); use `nvme1n1` (2 TB) for mail
storage and data (mount at `/var/mail` or `/srv`).

## Network

### WiFi (primary interface)

| Field | Value |
|---|---|
| Interface | `wlo1` (also: `wlp0s20f3`) |
| MAC address | `0c:dd:24:75:3d:ca` |
| Controller | Intel CNVi WiFi (Cannon Lake PCH, `00:14.3`) |
| Driver | `iwlwifi` |
| Bands | 2.4 GHz (802.11n) and 5 GHz (802.11ac / VHT, up to 160 MHz) |
| Current connection | `douze-bis`, channel 4 (2427 MHz), 20 MHz width |
| TX power | 20 dBm |

EUI-64 stable IPv6 address derived from MAC:
`2001:41d0:fc28:400:edd:24ff:fe75:3dca`

Note: the EUI-64 is derived from the MAC with the universal/local bit flipped:
`0c:dd:24` → `0e:dd:24` → prefix `edd:24ff:fe75:3dca`.

### Ethernet (secondary, unused)

| Field | Value |
|---|---|
| Interface | `eno2` (also: `enp0s31f6`) |
| MAC address | `a8:5e:45:a6:e1:97` |
| Controller | Intel I219-V (Cannon Lake PCH, `00:1f.6`) |
| Status | No carrier (cable not connected) |

The Ethernet port is available but not currently used. For a Mini-ITX board
in a likely compact enclosure, WiFi is the primary link.

## USB devices (at survey time)

| ID | Device |
|---|---|
| `1050:0407` | Yubikey 4/5 OTP+U2F+CCID |
| `046d:c548` | Logitech Bolt receiver (wireless keyboard/mouse) |
| `0403:6001` | FTDI FT232 USB-serial adapter (null-modem to build host) |
| `0b05:18a3` | ASUS AURA motherboard RGB controller |
| `8087:0aaa` | Intel Bluetooth 9460/9560 (Jefferson Peak) |
| `21c4:0809` | Lexar USB flash drive (installer ISO) |

## NixOS-relevant notes

- **WiFi driver**: `iwlwifi` — included in the NixOS kernel by default,
  no extra configuration needed.
- **Ethernet driver**: `e1000e` (Intel I219-V) — also in kernel by default.
- **NVMe**: both drives use the standard `nvme` kernel driver.
- **Bluetooth**: Intel AX200 co-located with WiFi CNVi — available if needed.
- **No dedicated GPU**: only Intel UHD 630 integrated graphics; headless
  server operation requires no GPU configuration.
- **BIOS mode**: UEFI supported and active (SMBIOS 3.2.1 present); install
  must use GPT + EFI partition (as specified in spec 0005).
- **VT-x / VT-d**: the i9-9900K supports both Intel VT-x (hardware
  virtualisation) and VT-d (IOMMU, for PCIe passthrough), but **VT-x is
  currently disabled in BIOS** (`x86/cpu: VMX (outside TXT) disabled by BIOS`
  in dmesg). Must be enabled manually before the NixOS install (spec 0005
  prerequisite): reboot into UEFI setup (Delete key), enable "Intel
  Virtualization Technology" and "Intel VT-d".
- **XMP**: Corsair kit is rated DDR4-2400 (XMP) but running at DDR4-2133
  (JEDEC default — XMP not enabled). For a server workload this is fine;
  enable XMP in BIOS only if memory bandwidth becomes a bottleneck.

## RAM upgrade

Both DIMM slots are already populated with 16 GB sticks. Reaching 64 GiB
(the board's maximum) requires replacing both DIMMs with 32 GB sticks.

**Recommended**: 2 × 32 GB DDR4 non-ECC unbuffered DIMMs in a low-profile
form factor (Corsair Vengeance LPX or equivalent). The Corsair
`CMK64GX4M2D3200C16` kit (2 × 32 GB, DDR4-3200 CL16, 1.35V rated) is a
suitable replacement.

Running DDR4-3200 sticks at DDR4-2400 / 1.2V (JEDEC default, XMP off) is
safe — all DDR4 ICs are required to meet JEDEC spec at 1.2V, and the lower
voltage runs cooler. Verify stability with `memtest86+` after swapping the
sticks.
