#!/usr/bin/env bash
set -euo pipefail

# =========================
# Fully automated Arch Linux installer
# Layout:
# nvme0n1p1 -> ESP
# nvme1n1p1 -> /boot
# nvme0n1p2 + nvme1n1p2 -> RAID0 (LUKS root)
# =========================

# --- Ensure two disks exists ---
if [[ ! -e /dev/nvme0n1 || ! -e /dev/nvme1n1 ]]; then
    echo "[!] Both /dev/nvme0n1 and /dev/nvme1n1 must be present. Exiting."
    exit 1
fi

# --- Prompt for LUKS password (with confirmation) ---
while true; do
    echo "Enter LUKS password (input hidden):"
    read -rs LUKS_PASS1
    echo
    echo "Confirm LUKS password:"
    read -rs LUKS_PASS2
    echo
    if [[ "$LUKS_PASS1" == "$LUKS_PASS2" ]]; then
        LUKS_PASS="$LUKS_PASS1"
        unset LUKS_PASS1 LUKS_PASS2
        break
    else
        echo "Passwords do not match. Please try again."
    fi
done

timedatectl set-ntp true

echo "[*] Partitioning disks..."
sgdisk --zap-all /dev/nvme0n1
sgdisk --zap-all /dev/nvme1n1

# nvme0n1: 512M ESP + rest root
parted -s /dev/nvme0n1 mklabel gpt \
  mkpart primary fat32 1MiB 513MiB \
  mkpart primary 513MiB 100% \
  set 1 esp on

# nvme1n1: 512M boot + rest root
parted -s /dev/nvme1n1 mklabel gpt \
  mkpart primary ext4 1MiB 513MiB \
  mkpart primary 513MiB 100%

partprobe /dev/nvme0n1
partprobe /dev/nvme1n1
sleep 2

# RAID0 root
echo "[*] Creating RAID0..."
yes | mdadm --create --verbose --level=0 --metadata=1.2 --raid-devices=2 /dev/md/root /dev/nvme0n1p2 /dev/nvme1n1p2

# Wipe RAID0 partitions securely
echo "[*] Securely wiping RAID0 partitions..."
cryptsetup open --type plain --sector-size 4096 --key-file /dev/urandom /dev/md/root to_be_wiped
dd if=/dev/zero of=/dev/mapper/to_be_wiped bs=1M status=progress
cryptsetup close to_be_wiped

echo "[*] Creating LUKS on /dev/md/root..."
echo -n "$LUKS_PASS" | cryptsetup -v luksFormat /dev/md/root -
echo -n "$LUKS_PASS" | cryptsetup open /dev/md/root root -

echo "[*] Formatting and mounting..."
mkfs.ext4 -F /dev/mapper/root
mount /dev/mapper/root /mnt

mkfs.fat -F32 /dev/nvme0n1p1
mkfs.ext4 -F /dev/nvme1n1p1

mkdir /mnt/boot
mount /dev/nvme1n1p1 /mnt/boot

mkdir /mnt/boot/efi
mount /dev/nvme0n1p1 /mnt/boot/efi

echo "[*] Installing base system..."
pacman -Sy --noconfirm reflector
reflector --latest 200 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# Ensure a non rate-limited mirror is selected
vim /etc/pacman.d/mirrorlist

pacstrap -K /mnt base linux-zen linux-firmware amd-ucode mdadm networkmanager gvim neovim man-db man-pages texinfo \
  alacritty base-devel bluez bluez-utils brightnessctl efibootmgr fish \
  flatpak fuzzel git grim grub mako mesa noto-fonts noto-fonts-emoji noto-fonts-cjk npm nvidia-open-dkms \
  nvidia-utils pipewire pipewire-alsa pipewire-audio pipewire-jack \
  pipewire-pulse pulsemixer sway swaybg swayidle swaylock tmux unzip \
  vulkan-radeon wireplumber wl-clipboard xdg-desktop-portal-gtk \
  xdg-desktop-portal-wlr xdg-user-dirs zig zls swtpm

genfstab -U /mnt >> /mnt/etc/fstab
mdadm --detail --scan >> /mnt/etc/mdadm.conf

echo "[*] Configuring inside chroot..."
arch-chroot /mnt bash -e <<'CHROOT'
ln -sf /usr/share/zoneinfo/Asia/Jakarta /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "lap" > /etc/hostname

# mkinitcpio
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block mdadm_udev encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# grub
sed -i 's/^#GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="cryptdevice=\/dev\/md\/root:root"/' /etc/default/grub || \
  echo 'GRUB_CMDLINE_LINUX="cryptdevice=/dev/md/root:root"' >> /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# passwords
echo "root:root" | chpasswd
useradd -m user
echo "user:user" | chpasswd
usermod -aG wheel user
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable bluetooth NetworkManager
systemctl --user enable pipewire wireplumber

sudo -u user bash -c '
mkdir -p ~/git && cd ~/git
git clone https://github.com/yuzu32/dotfiles.git
cd dotfiles
shopt -s dotglob
cp -r * ~/
rm -rf ~/.git
'

CHROOT

echo "[*] Installation done. dont forget to 'umount -R /mnt' then reboot"

#echo "[*] Installation done. Unmounting and rebooting..."
#umount -R /mnt
#reboot
