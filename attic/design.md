# motoko — Server Design Document

## Overview

**motoko** is a self-hosted NixOS server acting as:
- Mail server (SMTP/IMAP) for the domain `atlant.is`
- Web server (`www.atlant.is`, `atlant.is`)
- Photo server (`immich.atlant.is`)
- Local DNS resolver and DNS cache

It runs on an **ASUS ROG STRIX-X99** physical machine with an Intel CPU,
NVMe boot drive (`nvme0n1`), and wired Ethernet (`eno1`).
It is installed at IP `192.168.42.42` on LAN `192.168.42.0/24`,
with gateway/DNS at `192.168.42.1`.

---

## Hardware

| Item              | Value                          |
|-------------------|-------------------------------|
| Machine           | ASUS ROG STRIX-X99             |
| CPU               | Intel (KVM-capable, microcode updates enabled) |
| Boot drive        | NVMe (`nvme0n1`)              |
| Root filesystem   | ext4 on `nvme0n1p2` (UUID `bfbdd76b-faac-4138-ae14-e8eef694219d`) |
| EFI partition     | FAT32 on `nvme0n1p1` (UUID `86D0-D915`) |
| Swap              | None (no swap partition)      |
| Serial console    | `ttyS0` at 115200 baud (null-modem cable for remote access) |

NixOS 23.11 (`system.stateVersion = "23.11"`), x86_64-linux.

---

## Disk Layout

```
nvme0n1
├── nvme0n1p1  512 MiB  EFI System Partition (FAT32, label BOOT)
└── nvme0n1p2  rest     Root filesystem (ext4, label NIXOS)
```

`/tmp` is mounted as a `tmpfs` (8 GiB) to prevent temporary secrets from
touching the disk.

Bootloader: `systemd-boot` (EFI), with `canTouchEfiVariables = false`.

---

## NixOS Configuration Structure

The configuration lives under `/etc/nixos/` and is managed as a **Nix flake**
(`flake.nix`). It is pulled from a Git repository (`douzebis/major.git` on
GitHub) during installation.

### Key files

```
/etc/nixos/
├── bootstrap.nix          Machine-specific constants (hostname, IPs, SSH key, etc.)
├── bootstrap.tpl.nix      Template for bootstrap.nix (filled by bootstrap.bash)
├── configuration.nix      Main NixOS system configuration
├── flake.nix              Flake entry point — declares all modules
├── flake.lock             Pinned nixpkgs and sops-nix revisions
├── hardware-configuration.nix  Auto-generated hardware config
├── hosts                  Custom /etc/hosts entries
├── crons/cron-mail        Mail backup cron script
├── modules/               Service modules (one per concern)
│   ├── acme.nix           Let's Encrypt / ACME certificate provisioning
│   ├── custom.nix         Shared constants (domain name, ports)
│   ├── dkim.nix           OpenDKIM signing
│   ├── dnsmasq.nix        Local DNS resolver/cache
│   ├── docker.nix         Docker (v25) runtime
│   ├── immich.nix         Immich photo server (Docker-based)
│   ├── logrotate.nix      Log rotation cron
│   ├── nginx.nix          Nginx TLS SNI proxy
│   ├── postfix.nix        Postfix MTA + Dovecot IMAP
│   ├── restic.nix         Restic backup tooling
│   ├── s3.nix             OVH S3 credentials (via sops)
│   ├── sops.nix           sops-nix secret management
│   └── www.nix            Static website hosting (atlant.is, www.atlant.is)
└── motoko/                Host-specific secrets (SOPS-encrypted YAML)
    ├── acme/ovh-creds.yaml      OVH API credentials for ACME DNS challenge
    ├── atlantis-s3/ovh-creds.yaml   OVH S3 credentials
    ├── atlantis-s3/restic-mail.yaml Restic repository credentials for mail backup
    └── dkim/keys.yaml       DKIM private key and DNS TXT record
```

Files that are machine-specific and not tracked by Git (marked
`--assume-unchanged`): `bootstrap.nix`, `bootstrap.orig.nix`,
`configuration.nix`, `configuration.orig.nix`, `hardware-configuration.nix`,
`flake.nix`, `flake.lock`, `.sops.yaml`.

### Shared constants (`modules/custom.nix`)

```nix
sldDomain = "atlant.is";
immichPort = 2283;
```

### Bootstrap constants (`bootstrap.nix`)

```nix
hostLocalIp = "192.168.42.42";
hostName    = "motoko";
hostSystem  = "x86_64-linux";
bootDrive   = "nvme0n1";
captainEmail = "fred@atlant.is";
captainName  = "Frederic Ruget";
wiredDevice  = "eno1";
defaultRoute = "192.168.42.1";
dnServer     = "192.168.42.1";
sshAlgorithm = "ssh-ed25519";
```

---

## System Configuration (`configuration.nix`)

### Networking

- NetworkManager enabled.
- Wired interface `eno1`, DHCP.
- Static default gateway: `192.168.42.1`.
- DNS: `192.168.42.1` (the LAN router, which is augmented by local dnsmasq).
- ARP filter enabled on all interfaces and `eno1` to avoid ARP ambiguity.
- SSH (port 22) open in firewall.

### Locale / timezone

- Timezone: `Europe/Paris`.
- Keyboard: `fr` (French).
- Locale: `en_US.UTF-8`; measurement and time in `fr_FR.UTF-8`.

### Users

`mutableUsers = false` — all passwords are hashed in the config.

| User  | UID  | Groups              | Role                     |
|-------|------|---------------------|--------------------------|
| root  | 0    | —                   | Random opaque password, SSH key access |
| admin | 1000 | admin, wheel        | Primary admin, SSH key   |
| fred  | 1001 | fred, wheel         | Owner user, SSH key      |

All users share the same SSH ed25519 public key (from the installer's `~/.ssh/id_ed25519.pub`).
Password auth is disabled in sshd.

### Packages (system-wide)

`age`, `bind`, `git`, `iw`, `lm_sensors`, `nmon`, `tpm2-tools`, `tree`,
`wget`, `wpa_supplicant`, `yt-dlp`, `ffmpeg`, `lynx`, `w3m`, `qemu`,
`qemu-utils`, plus a `qemu-efi` shell script wrapper.

### Virtualisation

`libvirtd` enabled with KVM, OVMF (full, for UEFI VMs), swtpm (for TPM),
running as non-root. On shutdown: suspend. On boot: ignore.

`nix-ld` enabled (for VS Code remote server compatibility).

Nix flakes enabled: `nix-command`, `flakes`.

---

## Service Modules

### Secret management (`modules/sops.nix`)

Uses [sops-nix](https://github.com/Mic92/sops-nix). The age key is derived
from the machine's SSH host ed25519 key and stored at
`/var/lib/sops-nix/key.txt`. Secrets are encrypted YAML files in
`motoko/*/` subdirectories, decrypted at runtime to `/run/secrets/`.

The age public key for motoko is:
`age10tw9w9wce66sc4xu8nt9l6kg5222aede5mry7guk3p67ulmat40sljdu7t`

### TLS certificates (`modules/acme.nix`)

Uses Let's Encrypt ACME with **DNS-01 challenge** via the OVH DNS provider.
The OVH API credentials are stored in `motoko/acme/ovh-creds.yaml` (SOPS).
Four certificates are provisioned:

| Name    | Domain              | Used by          |
|---------|---------------------|------------------|
| `mail`  | `mail.atlant.is`    | Postfix, Dovecot |
| `www`   | `www.atlant.is`     | Nginx            |
| `root`  | `atlant.is`         | Nginx            |
| `immich`| `immich.atlant.is`  | Nginx → Immich   |

Certs live at `/var/lib/acme/<name>/`.

### DNS resolver (`modules/dnsmasq.nix`)

dnsmasq provides local DNS resolution for the LAN. Custom host entries are
in `/etc/nixos/hosts` (augments `/etc/hosts`). Ports 53 TCP/UDP are open
in the firewall. Notable host entries:

```
192.168.42.2    cibo
192.168.42.43   major
192.168.43.2    stone
```

### Nginx TLS proxy (`modules/nginx.nix`)

Nginx operates as a **TLS SNI passthrough proxy** on port 443 using the
`stream` module. It reads the SNI hostname from the TLS ClientHello and
forwards to:

- `127.0.0.1:444` (default — local nginx virtual hosts with TLS termination)
- `192.168.42.42:443` for `jellyfin.atlant.is` and `keycloak.atlant.is`
  (not currently active — commented out)
- `immich.atlant.is` entry is also commented out

Virtual hosts (terminating at `127.0.0.1:444`) serve:
- `www.atlant.is` — static files from `/var/nginx/www/`
- `atlant.is` — static files from `/var/nginx/root/` (also listens on port 80,
  which redirects to HTTPS)
- `immich.atlant.is` — reverse proxy to `http://127.0.0.1:2283`

### Mail server (`modules/postfix.nix`)

#### Postfix (MTA)

| Setting        | Value                        |
|----------------|------------------------------|
| Hostname       | `mail.atlant.is`             |
| Domain/origin  | `atlant.is`                  |
| Destinations   | `localhost`, `atlant.is`     |
| Local recipients | `admin`, `fred`            |
| Virtual aliases | `admin@atlant.is → admin`, `fred@atlant.is → fred` |
| Sender rewrite | `@motoko → @atlant.is`       |
| TLS cert/key   | `/var/lib/acme/mail/`        |
| Submission     | Ports 465 (SMTPS) and 587 (STARTTLS) enabled |
| SASL           | Dovecot-based (`private/auth` socket) |
| DKIM milter    | `unix:/run/opendkim/opendkim.sock` |

Firewall: ports 25, 465, 587, 143, 993 open.

#### Dovecot (IMAP)

| Setting        | Value                        |
|----------------|------------------------------|
| User/group     | `postfix` / `shadow`         |
| Auth backend   | `passwd-file` → `/etc/shadow` (system passwords) |
| User DB        | `passwd-file` → `/etc/passwd` |
| POP3           | Disabled                     |
| PAM            | Disabled                     |
| TLS            | Same cert as Postfix         |
| SASL socket    | `/var/lib/postfix/queue/private/auth` |

#### DKIM (`modules/dkim.nix`)

OpenDKIM signs outgoing mail for `atlant.is`. Selector: `mail`.
Key material is SOPS-encrypted in `motoko/dkim/keys.yaml`, decrypted to
`/run/secrets/dkim/` at runtime. OpenDKIM runs as the `postfix` user so
Postfix can reach its socket at `/run/opendkim/opendkim.sock`.

#### DNS records required (for reference)

```
mail 10800 IN A 109.190.53.206
     10800 IN MX 10 mail.atlant.is.
     10800 IN TXT "v=spf1 a mx a:mail.atlant.is -all"
mail._domainkey 10800 IN TXT "v=DKIM1;k=rsa;s=email;p=<public-key>"
_dmarc 10800 IN TXT "v=DMARC1;p=none;"
```
Reverse DNS: `109.190.53.206 → mail.atlant.is` (set via OVH manager).

### Immich photo server (`modules/immich.nix`)

Immich runs as a Docker-based service. A dedicated system user (`immich`,
UID/GID 300) is in the `docker` group so it can manage containers.
Immich listens on port 2283 internally; nginx proxies
`immich.atlant.is:443` → `http://127.0.0.1:2283`.

### Docker (`modules/docker.nix`)

Docker 25 (`pkgs.docker_25`) is enabled. Used by Immich.

### Secret file contents

Each secret file is a SOPS-encrypted YAML. Once decrypted, the contents are:

**`motoko/acme/ovh-creds.yaml`** — OVH API credentials for Let's Encrypt DNS-01:
```
ovh:
    acme_creds: |
        OVH_ENDPOINT=ovh-eu
        OVH_APPLICATION_KEY=xxxxxxxxxxxxxxxx
        OVH_APPLICATION_SECRET=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
        OVH_CONSUMER_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

**`motoko/atlantis-s3/ovh-creds.yaml`** — OVH Object Storage (S3-compatible):
```
ovh:
    s3_creds: |
        export AWS_DEFAULT_REGION="gra"
        export AWS_ACCESS_KEY_ID="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        export AWS_SECRET_ACCESS_KEY="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

**`motoko/atlantis-s3/restic-mail.yaml`** — Restic backup repository credentials:
```
restic:
    mail_creds: |
        export RESTIC_REPOSITORY="s3:s3.gra.io.cloud.ovh.net/atlantis/mail"
        export RESTIC_PASSWORD="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

**`motoko/dkim/keys.yaml`** — DKIM RSA keypair for `atlant.is`:
```
dkim:
    mail.private: |
        -----BEGIN PRIVATE KEY-----
        <RSA private key, 1024-bit>
        -----END PRIVATE KEY-----
    mail.txt: |
        mail._domainkey IN TXT ( "v=DKIM1; k=rsa; "
          "p=<base64-encoded RSA public key>" )
```

---

### Backup — Restic + OVH S3 (`modules/s3.nix`, `modules/restic.nix`)

Restic and the AWS CLI (`awscli2`) are installed. OVH S3 credentials are
stored in `motoko/atlantis-s3/ovh-creds.yaml` (SOPS), decrypted to
`/run/secrets/ovh/s3_creds`. Restic repository credentials are in
`motoko/atlantis-s3/restic-mail.yaml`, decrypted to
`/run/secrets/restic/mail_creds`.

Mail backup cron (`crons/cron-mail`, daily at 03:00):
- Sources and exports the two credential files.
- Backs up `/var/spool/mail/fred` to the Restic S3 repository.
- Logs to `/var/log/restic-mail/{out,err}.log`.

### Log rotation (`modules/logrotate.nix`)

logrotate runs daily at 04:00 via cron (`/etc/logrotate.d`).
Restic-mail logs rotate hourly, kept for 7 compressed generations.

---

## Installation Procedure

Installation is fully scripted. The workflow is:

### Phase 0 — Prepare target machine

1. Flash NixOS 23.11 minimal ISO to USB key.
2. On physical hardware: configure BIOS (TPM, VT-x, no CSM, no Secure Boot).
   On VM: configure UTM with bridged networking, UEFI, TPM.
3. Boot from the ISO. Enable serial console or set `passwd` for SSH access.

### Phase 1 — Remote bootstrap (`bootstrap.bash`)

Run from the *installer* machine (not the target):

```bash
./bootstrap.bash -n motoko -d nvme0n1 -w eno1 192.168.42.42
```

The script:
1. Optionally uploads pre-generated SSH host keypairs
   (`~/.ssh/id_ed25519_motoko`, etc.) to the target.
2. Detects target system, disks, and network via SSH.
3. Interactively confirms all parameters.
4. Partitions the NVMe drive (GPT: 512 MiB EFI + rest ext4, no swap).
5. Formats and mounts the partitions.
6. Runs `nixos-generate-config` on the target.
7. Clones the Git repo from GitHub (`douzebis/major.git`) into `/mnt/etc/nixos/`.
8. Fills `bootstrap.tpl.nix` → `bootstrap.nix` with machine-specific values.
9. Fills `configuration.tpl.nix` → `configuration.nix` (comments out
   wireless/optional sections if those variables are unset).
10. Marks the generated files as `--assume-unchanged` in Git.
11. Runs `nixos-install --no-root-passwd`.
12. Copies SSH host keypairs to the installed system.

### Phase 2 — First boot, flake activation (`00-install-flake.bash`)

After rebooting into the installed system, run as root/admin:

```bash
/etc/nixos/00-install-flake.bash
```

This copies `flake.tpl.nix` → `flake.nix`, marks it unchanged in Git, and
runs `nixos-rebuild switch` to apply the full flake-based config.

### Phase 3 — SOPS secret management (`01-install-sops.bash`)

```bash
/etc/nixos/01-install-sops.bash
```

1. Derives an age key from the SSH host ed25519 key using `ssh-to-age`.
2. Writes the age private key to `/var/lib/sops-nix/key.txt`.
3. Creates `/etc/nixos/.sops.yaml` with the machine's age public key.
4. Patches `flake.nix` to add `sops-nix.nixosModules.sops` and
   `modules/sops.nix`.
5. Rebuilds NixOS.

### Phase 4 — Web server (`02-install-www.bash`)

```bash
/etc/nixos/02-install-www.bash
```

1. Creates `/var/nginx/root/` owned by nginx.
2. Builds the Docusaurus documentation site (`/etc/nixos/doc/`).
3. Copies the built site to `/var/nginx/root/`.
4. Patches `flake.nix` to add `modules/acme.nix`, `modules/nginx.nix`,
   `modules/www.nix`.
5. Rebuilds NixOS.

### Phase 5 — Mail, DKIM, Immich, backups

Remaining modules (`modules/logrotate.nix`, `modules/s3.nix`,
`modules/restic.nix`, `modules/dkim.nix`, `modules/postfix.nix`,
`modules/docker.nix`, `modules/immich.nix`) are added to `flake.nix`
manually and `nixos-rebuild switch` is run.

The staged flake snapshots (`flake.01.nix` through `flake.03.nix`) appear
to be intermediate checkpoints of this progressive assembly.

---

## Network topology (LAN)

```
192.168.42.1    Router / gateway / DNS upstream
192.168.42.2    cibo
192.168.42.42   motoko  ← this server
192.168.42.43   major
192.168.43.2    stone
```

Tailscale-like entries also appear in `hosts`:
`100.111.17.126 git.s3ns.internal`, suggesting some machines are on a VPN.

---

## Security notes

- SSH password authentication is disabled.
- Root password is a random opaque hash (set during bootstrap).
- `/tmp` is RAM-backed (secrets never hit disk).
- All secrets are encrypted with age/SOPS; the decryption key is derived
  from the SSH host key and is therefore tied to the specific machine.
- `mutableUsers = false` enforces the declarative password configuration.
- DKIM, SPF, and DMARC records are configured for the mail domain.

---

## Open / notable items

- `immich.atlant.is` SNI forwarding in the nginx stream block is commented out;
  traffic reaches Immich only via the inner nginx virtual host (port 444).
- `jellyfin.atlant.is` and `keycloak.atlant.is` are referenced in nginx but
  appear not to be actively deployed (no dedicated NixOS modules).
- Wireless support is commented out throughout (`wirelessDevice`).
- DMARC policy is `p=none` (monitor only, no rejection).
