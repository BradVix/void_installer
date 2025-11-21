#!/bin/bash
# void-universal-installer-2025.sh
# Void Linux 2025 – Universal installer (Ethernet + WiFi auto-detect)
# Fixed: Seat group auto-created if missing + all previous fixes

set -e
clear
echo "=== VOID LINUX 2025 – UNIVERSAL FINAL INSTALLER ==="
echo "Ethernet = auto-skip WiFi | No Ethernet = asks for WiFi"
read -p "Press Enter to start..."

# ——— Internet detection ———
echo -e "\nChecking internet connection..."
if ping -c 2 repo-default.voidlinux.org &>/dev/null; then
    echo "Internet already working (Ethernet detected) → skipping WiFi setup"
    HAVE_INTERNET=1
else
    echo "No internet → setting up WiFi"
    HAVE_INTERNET=0
    read -p "WiFi interface (wlan0/wlp2s0/etc): " WIFI_IFACE
    read -p "SSID: " SSID
    read -s -p "Password (leave empty for open network): " WIFI_PASS; echo
    ip link set "$WIFI_IFACE" up
    if [ -n "$WIFI_PASS" ]; then
        wpa_passphrase "$SSID" "$WIFI_PASS" > /tmp/wpa.conf
        wpa_supplicant -B -i "$WIFI_IFACE" -c /tmp/wpa.conf
    else
        wpa_supplicant -B -i "$WIFI_IFACE" -c <(echo "network={ssid=\"$SSID\" key_mgmt=NONE}")
    fi
    dhcpcd "$WIFI_IFACE" &
    sleep 12
    ping -c 1 repo-default.voidlinux.org &>/dev/null || { echo "No internet!"; exit 1; }
    echo "WiFi connected"
fi

if [ $HAVE_INTERNET = 0 ]; then
    SAVE_IFACE="$WIFI_IFACE"
    SAVE_SSID="$SSID"
    SAVE_PASS="$WIFI_PASS"
else
    SAVE_IFACE=""; SAVE_SSID=""; SAVE_PASS=""
fi

# ——— Disk setup ———
read -p "Target disk (/dev/sda or /dev/nvme0n1): " DISK
read -p "Launch cfdisk now? (y/n): " P; [[ $P == y* ]] && cfdisk "$DISK"
[ -d /sys/firmware/efi ] && UEFI=1 || UEFI=0
[ $UEFI = 1 ] && read -p "EFI partition: " EFI_PART
read -p "Root partition: " ROOT_PART
read -p "Swap partition (optional, Enter to skip): " SWAP_PART

read -p "Full disk encryption? (y/N): " ENCRYPT; ENCRYPT=${ENCRYPT,,}
read -p "GRUB password? (y/N): " GRUBPASS; GRUBPASS=${GRUBPASS,,}

echo -e "\n1) i3   2) KDE Plasma   3) Hyprland   4) None"
read -p "Choice [4]: " DE; DE=${DE:-4}

echo -e "\n1) sudo   2) doas"
read -p "Choice [1]: " PRIV; PRIV=${PRIV:-1}

# ——— Partitioning & encryption ———
if [[ $ENCRYPT == y ]]; then
    cryptsetup luksFormat --type luks2 "$ROOT_PART"
    cryptsetup open "$ROOT_PART" cryptroot
    ROOT_DEV="/dev/mapper/cryptroot"
    mkfs.ext4 -F "$ROOT_DEV"
    LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")
else
    ROOT_DEV="$ROOT_PART"
    mkfs.ext4 -F "$ROOT_DEV"
fi
[ $UEFI = 1 ] && mkfs.vfat -F32 "$EFI_PART"
mount "$ROOT_DEV" /mnt
[ $UEFI = 1 ] && mkdir -p /mnt/boot/efi && mount "$EFI_PART" /mnt/boot/efi

# ——— Packages (add Hyprland repo if needed) ———
COMMON="base-system base-devel cryptsetup bash nano vim htop curl wget git iw wireless_tools dbus elogind seatd polkit pipewire wireplumber easyeffects linux linux-firmware xdg-desktop-portal-wlr xdg-desktop-portal-gtk"

case $DE in
  1) DE_PKGS="i3 i3status dmenu xorg xinit terminus-font" ;;
  2) DE_PKGS="kde-plasma sddm konsole NetworkManager" ;;
  3) 
    # Add Hyprland community repo for Void (needed for xdg-desktop-portal-hyprland)
    echo "repository=https://makrennel.github.io/hyprland-void/x86_64" > /etc/xbps.d/10-hyprland-void.conf
    xbps-install -S  # Refresh repos
    DE_PKGS="Hyprland kitty waybar wofi mako rofi-wayland swww xdg-desktop-portal-hyprland" ;;
  *) DE_PKGS="" ;;
esac

case $PRIV in
  2) PRIV_PKGS="opendoas"; PRIV_CFG="echo 'permit persist :wheel' > /etc/doas.conf" ;;
  *) PRIV_PKGS="sudo"; PRIV_CFG="echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel" ;;
esac

xbps-install -S -r /mnt -R "https://repo-default.voidlinux.org/current" $COMMON $DE_PKGS $PRIV_PKGS
xgenfstab -U /mnt >> /mnt/etc/fstab

# ——— Chroot configuration ———
cat > /mnt/install-final.sh <<'EOF'
#!/bin/bash
set -e
export SAVE_IFACE SAVE_SSID SAVE_PASS UEFI ENCRYPT GRUBPASS DE PRIV LUKS_UUID

# Hostname & hosts
read -p "Hostname [void]: " HOSTNAME; HOSTNAME=${HOSTNAME:-void}
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOS
127.0.0.1       localhost
::1             localhost
127.0.1.1       $HOSTNAME.localdomain $HOSTNAME
EOS

# Locale & timezone
read -p "Timezone (Europe/Berlin): " TZ
ln -sf /usr/share/zoneinfo/$TZ /etc/localtime
echo "en_US.UTF-8 UTF-8" >> /etc/default/libc-locales
xbps-reconfigure -f glibc-locales

# Bash forever
sed -i 's|^SHELL=.*|SHELL=/bin/bash|' /etc/default/useradd
chsh -s /bin/bash root
echo "Set root password:"; passwd

# User (fixed: create seat group if missing)
read -p "Create user? (y/n): " CU
if [[ $CU == y* ]]; then
    read -p "Username: " USER
    getent group seat >/dev/null || groupadd -r seat
    useradd -m -G wheel,seat,audio,video,input "$USER"
    passwd "$USER"
    $PRIV_CFG
    [[ $PRIV = 1 ]] && chmod 440 /etc/sudoers.d/10-wheel
fi

# Encryption
[[ $ENCRYPT == y ]] && echo "cryptroot UUID=$LUKS_UUID none luks,discard" > /etc/crypttab

# Networking
if [ $DE = 2 ]; then
    [ -n "$SAVE_SSID" ] && nmcli con add type wifi ifname "$SAVE_IFACE" con-name "$SAVE_SSID" ssid "$SAVE_SSID" ${SAVE_PASS:+wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$SAVE_PASS"}
    [ -n "$SAVE_SSID" ] && nmcli con mod "$SAVE_SSID" connection.autoconnect yes
    xbps-remove -Ryy wpa_supplicant dhcpcd iw wireless_tools 2>/dev/null || true
else
    [ -n "$SAVE_SSID" ] && mkdir -p /etc/wpa_supplicant && wpa_passphrase "$SAVE_SSID" "$SAVE_PASS" > "/etc/wpa_supplicant/wpa_supplicant-$SAVE_IFACE.conf"
fi

# Services
ln -s /etc/sv/{dbus,elogind,seatd,pipewire,wireplumber,pipewire-pulse} /var/service/
[[ $DE != 2 ]] && ln -s /etc/sv/{wpa_supplicant,dhcpcd} /var/service/ 2>/dev/null || true
[[ $DE = 2 ]] && ln -s /etc/sv/{NetworkManager,sddm} /var/service/

echo 'SEATD_GROUPS=wheel,seat' > /etc/sv/seatd/config

# GRUB password
[[ $GRUBPASS == y ]] && grub-mkpasswd-pbkdf2 | awk '/hash/{print "password_pbkdf2 root " $NF}' > /etc/grub.d/40_password

# Bootloader
if [ $UEFI = 1 ]; then
    xbps-install -y grub-x86_64-efi
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Void
else
    grub-install "$DISK"
fi

# Encryption kernel parameters
[[ $ENCRYPT == y ]] && sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=4 rd.luks.uuid=$LUKS_UUID root=/dev/mapper/cryptroot\"|" /etc/default/grub

xbps-reconfigure -fa
echo -e "\nINSTALLATION COMPLETE! Reboot now."
EOF

chmod +x /mnt/install-final.sh
xchroot /mnt /install-final.sh
rm /mnt/install-final.sh

umount -R /mnt
echo -e "\nAll done! Reboot and enjoy your perfect Void system."
