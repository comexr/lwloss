#!/usr/bin/env bash

set -eoux pipefail

# Configure Anaconda

# Install Anaconda, Webui if >= F42
SPECS=(
    "libblockdev-btrfs"
    "libblockdev-lvm"
    "libblockdev-dm"
    "anaconda-live"
)
if [[ "$IMAGE_TAG" =~ lts ]]; then
    dnf config-manager --set-enabled centos-release-kmods-kernel
    dnf copr enable -y jreilly/anaconda-webui

    SPECS+=("anaconda-webui")
elif [[ "$(rpm -E %fedora)" -ge 42 ]]; then
    SPECS+=("anaconda-webui")
fi
dnf install -y "${SPECS[@]}"

dnf config-manager --set-disabled centos-hyperscale &>/dev/null || true

# Anaconda Profile Detection

# Bluefin
tee /etc/anaconda/profile.d/bluefin.conf <<'EOF'
# Anaconda configuration file for Bluefin

[Profile]
# Define the profile.
profile_id = bluefin

[Profile Detection]
# Match os-release values
os_id = bluefin

[Network]
default_on_boot = FIRST_WIRED_WITH_LINK

[Bootloader]
efi_dir = fedora
menu_auto_hide = True

[Storage]
default_scheme = BTRFS
btrfs_compression = zstd:1
default_partitioning =
    /     (min 1 GiB, max 70 GiB)
    /home (min 500 MiB, free 50 GiB)
    /var  (btrfs)

[User Interface]
custom_stylesheet = /usr/share/anaconda/pixmaps/silverblue/fedora-silverblue.css
hidden_spokes =
    NetworkSpoke
    PasswordSpoke
    UserSpoke
hidden_webui_pages =
    anaconda-screen-accounts

[Localization]
use_geolocation = False
EOF

if [[ "${IMAGE_TAG}" =~ lts ]]; then
    sed -i 's/^ID=.*/ID=bluefin/' /usr/lib/os-release
    echo "VARIANT_ID=bluefin" >>/usr/lib/os-release
fi

# Configure
. /etc/os-release
if [[ "$IMAGE_TAG" =~ gts ]]; then
    echo "Bluefin ${IMAGE_TAG^^} release $VERSION_ID (${VERSION_CODENAME:=Big Bird})" >/etc/system-release
else
    echo "Bluefin release $VERSION_ID ($VERSION_CODENAME)" >/etc/system-release
fi
sed -i 's/ANACONDA_PRODUCTVERSION=.*/ANACONDA_PRODUCTVERSION=""/' /usr/{,s}bin/liveinst || true
sed -i 's|^Icon=.*|Icon=/usr/share/pixmaps/fedora-logo-icon.png|' /usr/share/applications/liveinst.desktop || true
sed -i 's| Fedora| Bluefin|' /usr/share/anaconda/gnome/fedora-welcome || true
sed -i 's|Activities|in the dock|' /usr/share/anaconda/gnome/fedora-welcome || true

# Get Artwork
git clone --depth=1 https://github.com/ublue-os/packages.git /root/packages
mkdir -p /usr/share/anaconda/pixmaps/silverblue
cp -r /root/packages/bluefin/fedora-logos/src/anaconda/* /usr/share/anaconda/pixmaps/silverblue/
rm -rf /root/packages

# Interactive Kickstart
tee -a /usr/share/anaconda/interactive-defaults.ks <<EOF
ostreecontainer --url=$IMAGE_REF:$IMAGE_TAG --transport=containers-storage --no-signature-verification
%include /usr/share/anaconda/post-scripts/install-configure-upgrade.ks
%include /usr/share/anaconda/post-scripts/disable-fedora-flatpak.ks
%include /usr/share/anaconda/post-scripts/install-flatpaks.ks
%include /usr/share/anaconda/post-scripts/secureboot-enroll-key.ks
EOF

# Signed Images
tee /usr/share/anaconda/post-scripts/install-configure-upgrade.ks <<EOF
%post --erroronfail
bootc switch --mutate-in-place --enforce-container-sigpolicy --transport registry $IMAGE_REF:$IMAGE_TAG
%end
EOF

# Disable Fedora Flatpak
tee /usr/share/anaconda/post-scripts/disable-fedora-flatpak.ks <<'EOF'
%post --erroronfail
systemctl disable flatpak-add-fedora-repos.service
%end
EOF

# Install Flatpaks
tee /usr/share/anaconda/post-scripts/install-flatpaks.ks <<'EOF'
%post --erroronfail --nochroot
deployment="$(ostree rev-parse --repo=/mnt/sysimage/ostree/repo ostree/0/1/0)"
target="/mnt/sysimage/ostree/deploy/default/deploy/$deployment.0/var/lib/"
mkdir -p "$target"
rsync -aAXUHKP /var/lib/flatpak "$target"
%end
EOF