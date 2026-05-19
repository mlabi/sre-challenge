# Ubuntu Server 26.04 unattended install

How to take a blank ThinkCentre (or any amd64 box) to a usable Ubuntu
host that the Ansible playbooks can SSH into without further prompts.

Uses Ubuntu's autoinstall (cloud-init NoCloud datasource): two USB
sticks per box — one with the install ISO, one with `user-data` +
`meta-data` labelled `CIDATA`.

## What gets installed

The rendered `user-data` configures each box with:

- hostname `box-N`
- user `labi` with `NOPASSWD` sudo and only SSH-key login (password
  login disabled)
- the lab SSH public key in `authorized_keys`
- DHCP on the first Ethernet adapter
- direct disk layout, no LVM (single-disk lab boxes)
- packages: `openssh-server`, `curl`, `ca-certificates`, `gnupg`,
  `python3` (everything Ansible needs to land on the box)

## One-time prep on the controller

1. Generate the lab SSH key (once per fresh laptop):

   ```bash
   ./deploy/ansible/bootstrap/00-generate-ssh-key.sh
   ```

   Writes `~/.ssh/labi_lab_ed25519{,.pub}`.

2. Replace the placeholder password hash in `user-data.tpl`. The
   default is unusable on purpose. Generate a real one:

   ```bash
   mkpasswd -m sha-512    # asks for password interactively, prints $6$… hash
   # or, if you don't have whois:
   openssl passwd -6
   ```

   Paste the `$6$…` hash into `user-data.tpl` in the `identity.password`
   field. Password login stays disabled (`ssh.allow-pw: false`) — this
   hash is only used so `sudo` works after install and the install
   doesn't refuse to set up the account.

## Render per-host `user-data`

```bash
cd deploy/ansible/bootstrap/ubuntu
./generate.sh
```

Renders `dist/box-1/`, `dist/box-2/`, `dist/box-3/` each containing the
two files cloud-init expects: `user-data` and `meta-data`. The SSH
public key gets substituted in automatically. Hostnames are hard-coded
in the script — if you have a different lab size, edit the trailing
`render "box-N"` lines.

## Flash the USB sticks

For each box you'll prepare two sticks: the Ubuntu installer ISO and a
small FAT32 stick with `user-data` / `meta-data`.

### Stick 1 — Ubuntu Server installer

Download `ubuntu-26.04-live-server-amd64.iso` from
https://releases.ubuntu.com/.

Flash it onto a stick (≥ 4 GB) using whichever tool you prefer:

```bash
# macOS — find the right disk number first, this WIPES it:
diskutil list                                        # identify diskN
diskutil unmountDisk /dev/diskN
sudo dd if=ubuntu-26.04-live-server-amd64.iso \
        of=/dev/rdiskN bs=4m status=progress
diskutil eject /dev/diskN
```

GUI alternative: Balena Etcher, Raufus (Windows), Ubuntu's "Startup
Disk Creator". Each works.

### Stick 2 — `CIDATA` (cloud-init NoCloud)

Cloud-init looks for a filesystem labelled exactly `CIDATA` containing
the two files at the root. Any small USB stick works (256 MB is
plenty).

```bash
# macOS — format FAT32 with label CIDATA, then copy the rendered files
diskutil list                                        # identify the second diskN
diskutil eraseDisk MS-DOS CIDATA MBR /dev/diskN
cp dist/box-1/user-data dist/box-1/meta-data /Volumes/CIDATA/
diskutil eject /dev/diskN
```

Linux equivalent:

```bash
sudo mkfs.vfat -n CIDATA /dev/sdX1
sudo mount /dev/sdX1 /mnt
sudo cp dist/box-1/{user-data,meta-data} /mnt/
sudo umount /mnt
```

> Tip: if you have a 16 GB+ stick you can put both ISO and CIDATA on
> the same stick by partitioning it (one bootable FAT32 with the ISO,
> one small FAT32 labelled `CIDATA`). The two-stick flow above is just
> the simplest to script.

## Install on the box

1. Plug **both** USB sticks into the target box.
2. Power it on, hit the BIOS/UEFI boot key (F12 on ThinkCentres) and
   pick the Ubuntu USB.
3. At the GRUB menu select **"Try or install Ubuntu Server"**.
4. The installer detects the `CIDATA` stick, asks once **"Continue
   with autoinstall? (yes/no)"** — type `yes` and press enter. After
   that it runs unattended (~10–15 min including the post-install
   reboot).
5. When the box reboots and shows the login prompt: pull both USB
   sticks. Done.

## Verify

Find the address the DHCP server handed out (router admin page, `arp`
on the controller, or just `ping box-1.local` if mDNS works in your
LAN) and:

```bash
ssh labi@<box-IP>          # should land straight in, no password
sudo whoami                # 'root', no prompt
```

## Wire it into the inventory

Edit `deploy/ansible/inventory/hosts.yml` so `ansible_host` of the
first `k3s_server` matches the box's IP, then:

```bash
make ping                  # Ansible reachability across the inventory
make all                   # k3s + everything else
```

## Repeat for each box

`./generate.sh` already renders all `box-N` outputs. For every new
box: re-flash the `CIDATA` stick with the next `dist/box-N/*` pair and
repeat the install. The ISO stick is the same across boxes.
