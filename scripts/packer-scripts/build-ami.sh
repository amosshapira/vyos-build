#!/bin/bash

set -x
set -e

# This script is executed after the UserData script
# (packer-scripts/aws-user-data.sh) moved the Ubuntu root filesystem to a
# "side disk" and rebooted, allowing us to build VyOS on /dev/xvda from
# scratch.
# Packer then will burn an AMI from /dev/xvda

# point SCRIPTS to the location of current script, this is where we'll copy
# other scripts from
SCRIPTS=$(dirname $0)

. ${SCRIPTS}/vyos_release.sh

# Reformat the root disk
parted --script /dev/xvda mklabel msdos
parted --script --align optimal /dev/xvda mkpart primary 0% 100%
mkfs.ext4 -L cloudimg-rootfs /dev/xvda1
parted --script /dev/xvda set 1 boot

# install VyOS from ISO
#curl -o /tmp/vyos.iso -L http://mirror.vyos.net/iso/release/${VYOS_RELEASE}/vyos-${VYOS_RELEASE}-amd64.iso
# This one seems to be faster Australian mirror
#curl -o /tmp/vyos.iso -L http://vyos-mirror.per.webinabox.net.au/iso/release/${VYOS_RELEASE}/vyos-${VYOS_RELEASE}-amd64.iso
mkdir /mnt/cdsquash /mnt/cdrom /mnt/wroot
mount -o loop,ro ${SCRIPTS}/vyos.iso /mnt/cdrom
mount -o loop,ro /mnt/cdrom/live/filesystem.squashfs /mnt/cdsquash/
mount /dev/xvda1 /mnt/wroot
mkdir -p /mnt/wroot/boot/${VYOS_RELEASE}/live-rw
cp -p /mnt/cdrom/live/filesystem.squashfs /mnt/wroot/boot/${VYOS_RELEASE}/${VYOS_RELEASE}.squashfs
find /mnt/cdsquash/boot -maxdepth 1 \( -type f -o -type l \) -exec cp -dpv {} /mnt/wroot/boot/${VYOS_RELEASE}/ \;
mkdir /mnt/squashfs
mkdir /mnt/inst_root
mount -o loop,ro /mnt/wroot/boot/${VYOS_RELEASE}/${VYOS_RELEASE}.squashfs /mnt/squashfs/
mount -o noatime,upperdir=/mnt/wroot/boot/${VYOS_RELEASE}/live-rw,lowerdir=/mnt/squashfs -t overlayfs overlayfs /mnt/inst_root
touch /mnt/inst_root/opt/vyatta/etc/config/.vyatta_config
chroot --userspec=root:vyattacfg /mnt/inst_root/ cp /opt/vyatta/etc/config.boot.default /opt/vyatta/etc/config/config.boot
chmod 0775 /mnt/inst_root/opt/vyatta/etc/config/config.boot

# 1. Insert eth0 as a DHCP interface
# 2. disable ssh password authentication
sed -i -r \
  -e '/^interfaces \{/ a \    ethernet eth0 \{\n        address dhcp\n    \}' \
  -e '/^system \{/i service \{\n    ssh \{\n        disable-password-authentication\n        port 22\n    \}\n\}' \
  -e '/login \{/i \    host-name VyOS-AMI' \
  -e 's/^([[:blank:]]+)encrypted-password\b.*/\1encrypted-password "*"/' \
  -e '/[[:blank:]]+plaintext-password\b/d' \
  /mnt/inst_root/opt/vyatta/etc/config/config.boot

mkdir /mnt/wroot/boot/grub
echo '(hd0)  /dev/xvda' > /mnt/wroot/boot/grub/device.map
mount --bind /dev /mnt/inst_root/dev
mount --bind /proc /mnt/inst_root/proc
mount --bind /sys /mnt/inst_root/sys
mount --bind /mnt/wroot/ /mnt/inst_root/boot
mount --bind /dev/pts /mnt/inst_root/dev/pts
mkdir /mnt/inst_root/run
mount --bind /run /mnt/inst_root/run
cp /etc/resolv.conf /mnt/inst_root/etc/resolv.conf
chroot /mnt/inst_root grub-install --no-floppy --root-directory=/boot /dev/xvda

echo "set default=0
set timeout=0

menuentry 'VyOS AMI (HVM) ${VYOS_RELEASE}' {
  linux /boot/${VYOS_RELEASE}/vmlinuz boot=live quiet root=LABEL=cloudimg-rootfs vyatta-union=/boot/${VYOS_RELEASE} console=ttyS0
  initrd /boot/${VYOS_RELEASE}/initrd.img
}" > /mnt/wroot/boot/grub/grub.cfg

# install startup service to fetch ssh public key from metadata
cp ${SCRIPTS}/ec2-fetch-ssh-public-key /mnt/inst_root/etc/init.d/ec2-fetch-ssh-public-key
chroot /mnt/inst_root insserv ec2-fetch-ssh-public-key --default

cp ${SCRIPTS}/ec2-execute-user-data /mnt/inst_root/etc/init.d/ec2-execute-user-data
chroot /mnt/inst_root insserv ec2-execute-user-data --default

echo 'tmpfs /var/run tmpfs nosuid,nodev 0 0' > /mnt/inst_root/etc/fstab

rm /mnt/inst_root/etc/resolv.conf

umount /mnt/inst_root/dev/pts
umount /mnt/inst_root/run
umount /mnt/inst_root/boot
umount /mnt/inst_root/sys
umount /mnt/inst_root/proc
umount /mnt/inst_root/dev
umount /mnt/inst_root
umount /mnt/squashfs
umount /mnt/wroot
umount /mnt/cdsquash
umount /mnt/cdrom
