# Ensure the generated root filesystem configures the actual Zybo Ethernet
# interface name used by this board. PetaLinux's subsystem network setting
# emits an eth0 stanza, but the running system exposes enx000a35001e53.

ROOTFS_POSTPROCESS_COMMAND:append = " zybo_install_fixed_network_interfaces;"

zybo_install_fixed_network_interfaces() {
    install -d ${IMAGE_ROOTFS}/etc/network

    cat > ${IMAGE_ROOTFS}/etc/network/interfaces <<'INTERFACES_EOF'
# /etc/network/interfaces -- static direct host-to-Zybo development link

auto lo
iface lo inet loopback

auto enx000a35001e53
iface enx000a35001e53 inet static
    address 192.168.10.2
    netmask 255.255.255.0
INTERFACES_EOF
}
