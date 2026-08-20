# Build and Reproduce the Zybo Z7 AES-CTR Accelerator

This guide rebuilds the AES-128 CTR FPGA accelerator extension from the
repository contents.

The repository extends the pinned Zybo Z7 Linux-FPGA acceleration platform
contained in the `platform/` Git submodule.

The rebuild flow covers:

- AES-CTR VHDL sources maintained by the HDL Designer project
- ModelSim RTL regression
- Vivado hardware project recreation from committed Tcl and packaged IP
- bitstream generation and XSA export
- fresh PetaLinux project creation from the AES XSA
- application of the pinned platform PetaLinux base
- application of the AES-specific PetaLinux overlay
- Linux image generation
- verification of the AES driver, applications, and DMA device-tree binding
- generation of deployable boot artifacts

---

# 1. Tested environment

## Hardware

- Board: Digilent Zybo Z7-20
- SoC: Xilinx Zynq-7020

## Tool versions

- Vivado 2025.2 on Windows
- PetaLinux 2025.2 on Ubuntu 22.04.5 LTS

## Development split

Windows:

- HDL Designer source maintenance
- ModelSim RTL regression
- Vivado project recreation
- synthesis and implementation
- bitstream generation
- XSA export

Ubuntu:

- PetaLinux project recreation
- Linux image build
- boot-image packaging
- Linux driver and application integration

---

# 2. Repository layout

Important repository inputs are:

```text
platform/
    Pinned base Linux-FPGA platform

hardware/
    hdl_designer/
        zybo_aes_hdl.hdp
        zybo_aes_hdl_lib/
            hdl/
            hds/

    ip/
        zybo_accel_ctrl_1_0/

    vivado/
        create_project.tcl
        create_block_design.tcl

linux/
    driver/
    apps/
    petalinux/

tests/
    rtl/
        modelsim/
```

The VHDL files used by Vivado are maintained directly under:

```text
hardware/hdl_designer/zybo_aes_hdl_lib/hdl/
```

There is intentionally no duplicate `hardware/rtl/` directory. The Vivado
recreation script consumes the HDL Designer VHDL files directly.

---

# 3. Clone the repository

The base platform is included as a Git submodule, so clone recursively.

## Windows

```powershell
$REPO_URL = "https://github.com/ShahinFi/zybo-z7-aes-ctr-accelerator.git"
$REPO_WIN = "C:\FPGA_Tools\zybo-z7-aes-ctr-accelerator"

git clone --recurse-submodules $REPO_URL $REPO_WIN
```

## Ubuntu

```bash
REPO_URL="https://github.com/ShahinFi/zybo-z7-aes-ctr-accelerator.git"
REPO="$HOME/projects/zybo-z7-aes-ctr-accelerator"

git clone --recurse-submodules "$REPO_URL" "$REPO"
```

For an existing clone:

```bash
cd ~/projects/zybo-z7-aes-ctr-accelerator
git submodule update --init --recursive
```

The `platform/` submodule must remain at the revision recorded by the AES
repository.

---

# 4. RTL regression

The committed ModelSim regression suite is located at:

```text
tests/rtl/modelsim/
```

The regression entry point is:

```text
tests/rtl/modelsim/run_all.do
```

The final suite contains 11 tests covering:

- reset behavior
- NIST AES-CTR vectors
- input AXI-Stream handshaking
- output backpressure
- partial blocks
- start requests while busy
- counter behavior
- reset during operation
- multiple transactions
- continuous streaming
- randomized stress

The final regression contains 16,955 checks with zero failures.

---

# 5. Recreate the Vivado hardware project

Run this section on Windows using Vivado 2025.2.

## 5.1 Define paths

```powershell
$REPO_WIN = "C:\FPGA_Tools\zybo-z7-aes-ctr-accelerator"
$VIVADO = "C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"

$VIVADO_BUILD_DIR = "$REPO_WIN\build\vivado\zybo_z7_20_aes_ctr"
```

If Vivado is installed elsewhere, adjust `$VIVADO`.

## 5.2 Remove an old generated project if present

```powershell
Remove-Item -Recurse -Force $VIVADO_BUILD_DIR -ErrorAction SilentlyContinue
```

## 5.3 Recreate the project

```powershell
Set-Location $REPO_WIN

& $VIVADO `
  -mode batch `
  -source "$REPO_WIN\hardware\vivado\create_project.tcl"
```

The generated project is created under:

```text
build\vivado\zybo_z7_20_aes_ctr\
```

The recreation script:

- targets the Zybo Z7-20 / XC7Z020
- loads the AES-extended `zybo_accel_ctrl_1_0` packaged IP
- adds the AES VHDL directly from the HDL Designer `hdl/` directory
- recreates the final `system` block design
- generates the block-design outputs
- creates the top-level HDL wrapper

The recreated block design includes:

- Zynq processing system
- AXI DMA
- AES-128 CTR streaming accelerator
- AES-extended AXI-Lite control IP

The main address assignments are:

```text
AXI DMA       0x40400000
Control IP    0x43C00000
```

---

# 6. Generate the bitstream and export the XSA

Open the recreated Vivado project:

```text
build\vivado\zybo_z7_20_aes_ctr\zybo_z7_20_aes_ctr.xpr
```

In Vivado:

1. Run **Synthesis**.
2. Run **Implementation**.
3. Run **Generate Bitstream**.
4. Wait until bitstream generation completes successfully.
5. Open **File -> Export -> Export Hardware**.
6. Enable **Include bitstream**.

Create the following directory if needed:

```text
build\xsa\
```

Export the hardware handoff as:

```text
build\xsa\zybo_z7_20_aes_ctr_integration.xsa
```

Confirm it exists from PowerShell:

```powershell
$REPO_WIN = "C:\FPGA_Tools\zybo-z7-aes-ctr-accelerator"
$XSA_WIN = "$REPO_WIN\build\xsa\zybo_z7_20_aes_ctr_integration.xsa"

Get-Item $XSA_WIN
```

---

# 7. Copy the XSA to the PetaLinux host

On Ubuntu:

```bash
mkdir -p ~/xsa
```

Example from Windows PowerShell:

```powershell
$PETALINUX_HOST = "petalinux-vm"
$XSA_WIN = "C:\FPGA_Tools\zybo-z7-aes-ctr-accelerator\build\xsa\zybo_z7_20_aes_ctr_integration.xsa"

scp $XSA_WIN "dev@$PETALINUX_HOST:/home/dev/xsa/zybo_z7_20_aes_ctr_integration.xsa"
```

---

# 8. Create a fresh PetaLinux project

Run this section on Ubuntu.

## 8.1 Load PetaLinux 2025.2

```bash
source ~/tools/petalinux/2025.2/settings.sh
```

## 8.2 Define build paths

```bash
REPO="$HOME/projects/zybo-z7-aes-ctr-accelerator"
XSA="$HOME/xsa/zybo_z7_20_aes_ctr_integration.xsa"

PLNX_ROOT="$HOME/petalinux"
PLNX_NAME="zybo-z7-aes-ctr-build"
PLNX="$PLNX_ROOT/$PLNX_NAME"
```

## 8.3 Create a clean project

```bash
rm -rf "$PLNX"
mkdir -p "$PLNX_ROOT"
cd "$PLNX_ROOT"

petalinux-create -t project --template zynq -n "$PLNX_NAME"
cd "$PLNX"
```

PetaLinux 2025.2 may report that the `-t project` form is deprecated. The
command remains accepted by the verified 2025.2 installation.

---

# 9. Import the AES hardware description

Run:

```bash
petalinux-config \
  --get-hw-description="$XSA" \
  --silentconfig
```

A successful import ends with:

```text
[INFO] Successfully configured project
```

---

# 10. Apply the repository-controlled PetaLinux inputs

The AES repository uses two PetaLinux layers.

The pinned platform snapshot provides the common base configuration.

Apply it first:

```bash
rsync -a \
  "$REPO/platform/linux/petalinux/project-spec/" \
  project-spec/
```

Then apply the AES-specific overlay:

```bash
rsync -a \
  "$REPO/linux/petalinux/project-spec/" \
  project-spec/
```

The AES overlay supplies the AES-specific rootfs configuration and recipes for:

```text
zybo-aes-ctr-accel
zybo-aes-ctr-test
zybo-aes-ctr-bench
```

It also supplies the final image customization used by the verified AES system.

Common platform configuration and device-tree infrastructure are inherited from
the pinned platform snapshot rather than duplicated in the AES overlay.

---

# 11. Re-apply the PetaLinux configuration

Run:

```bash
petalinux-config --silentconfig
petalinux-config -c rootfs --silentconfig
```

Both commands should complete successfully.

Confirm the AES packages are enabled:

```bash
grep -nE 'CONFIG_zybo-' project-spec/configs/rootfs_config
```

Expected entries:

```text
CONFIG_zybo-aes-ctr-accel=y
CONFIG_zybo-aes-ctr-bench=y
CONFIG_zybo-aes-ctr-test=y
```

---

# 12. Build the Linux image

Run:

```bash
petalinux-build
```

A successful build ends with:

```text
[INFO] Successfully built project
```

A message such as:

```text
Failed to copy built images to tftp dir: /tftpboot
```

does not affect this SD-card-oriented build flow.

---

# 13. Verify the AES packages

## 13.1 Confirm that the AES recipes were built

```bash
find build/tmp/work -maxdepth 3 -type d \
  \( -name 'zybo-aes-ctr-accel' \
     -o -name 'zybo-aes-ctr-test' \
     -o -name 'zybo-aes-ctr-bench' \) \
  2>/dev/null | sort
```

Expected recipe directories include:

```text
zybo-aes-ctr-accel
zybo-aes-ctr-test
zybo-aes-ctr-bench
```

## 13.2 Confirm package inclusion in the final image

```bash
grep -iE 'zybo-aes-ctr-(accel|test|bench)' \
  images/linux/*.manifest
```

Expected entries include:

```text
kernel-module-zybo-aes-ctr-accel-...
zybo-aes-ctr-accel
zybo-aes-ctr-bench
zybo-aes-ctr-test
```

This confirms that the AES driver package and both AES user-space applications
are included in the generated Linux image.

---

# 14. Verify the DMA device-tree binding

The repository-controlled device-tree overlay associates both AXI DMA channels
with the AES control device:

```dts
&zybo_accel_ctrl_0 {
    dmas = <&axi_dma_0 0>, <&axi_dma_0 1>;
    dma-names = "tx", "rx";
};
```

Verify the final compiled DTB:

```bash
dtc -I dtb -O dts images/linux/system.dtb 2>/dev/null | grep 'dma-names'
```

Expected output:

```text
dma-names = "tx\0rx";
```

The `\0` is the decompiled representation of the two-string device-tree
property:

```text
"tx", "rx"
```

The generated hardware node uses:

```text
compatible = "xlnx,zybo-accel-ctrl-1.0";
```

The AES kernel driver matches this compatible string.

---

# 15. Package BOOT.BIN

Run inside the fresh PetaLinux project:

```bash
cd "$PLNX"
```

Package the Zynq boot image:

```bash
petalinux-package boot \
  --fsbl images/linux/zynq_fsbl.elf \
  --fpga images/linux/system.bit \
  --u-boot \
  --force
```

A successful package operation should produce:

```text
images/linux/BOOT.BIN
```

Verify the main deployment artifacts:

```bash
ls -lh \
  images/linux/BOOT.BIN \
  images/linux/image.ub \
  images/linux/boot.scr \
  images/linux/rootfs.tar.gz \
  images/linux/system.bit \
  images/linux/system.dtb
```

---

# 16. Prepare the SD card

The verified system uses a two-partition SD-card layout.

| Partition | Filesystem | Purpose |
|---|---|---|
| BOOT | FAT32 | `BOOT.BIN`, `image.ub`, `boot.scr` |
| rootfs | ext4 | extracted Linux root filesystem |

A practical layout is:

- BOOT: approximately 512 MiB
- rootfs: remaining card space

Insert the SD card into the Ubuntu system or pass it through to the Ubuntu VM.

Identify it carefully:

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS,MODEL,TRAN
```

Set the device only after confirming the correct SD card.

Example:

```bash
SD_DEV=/dev/sdb
```

Unmount any automatically mounted partitions:

```bash
sudo umount "${SD_DEV}1" 2>/dev/null || true
sudo umount "${SD_DEV}2" 2>/dev/null || true
```

Create mount points:

```bash
BOOT_MNT=/mnt/zybo_boot
ROOTFS_MNT=/mnt/zybo_rootfs

sudo mkdir -p "$BOOT_MNT" "$ROOTFS_MNT"
```

Mount both partitions:

```bash
sudo mount "${SD_DEV}1" "$BOOT_MNT"
sudo mount "${SD_DEV}2" "$ROOTFS_MNT"
```

Confirm the mount points before copying anything:

```bash
df -h "$BOOT_MNT" "$ROOTFS_MNT"
```

---

# 17. Deploy the rebuilt image to the SD card

Run from the fresh PetaLinux project:

```bash
cd "$PLNX"
```

Replace the BOOT partition files:

```bash
sudo rm -f \
  "$BOOT_MNT/BOOT.BIN" \
  "$BOOT_MNT/image.ub" \
  "$BOOT_MNT/boot.scr"

sudo cp -v \
  images/linux/BOOT.BIN \
  images/linux/image.ub \
  images/linux/boot.scr \
  "$BOOT_MNT/"
```

Replace the root filesystem:

```bash
sudo find "$ROOTFS_MNT" -mindepth 1 -maxdepth 1 \
  ! -name lost+found \
  -exec rm -rf {} +

sudo tar -xpf images/linux/rootfs.tar.gz -C "$ROOTFS_MNT"
```

Flush writes:

```bash
sync
```

Verify the boot files:

```bash
ls -lh "$BOOT_MNT"
```

Then unmount cleanly:

```bash
sudo umount "$BOOT_MNT"
sudo umount "$ROOTFS_MNT"
sync
```

Remove the card only after both partitions have been unmounted.

---

# 18. Boot the Zybo Z7-20

1. Insert the prepared microSD card.
2. Configure the Zybo Z7-20 for SD-card boot.
3. Connect the PROG/UART Micro-USB connection.
4. Connect Ethernet if SSH access will be used.
5. Power on the board.

---

# 19. Serial console

On Windows, identify the Zybo serial port:

```powershell
Get-CimInstance Win32_SerialPort |
Select-Object DeviceID, Name, Description
```

Open the console using the detected port.

Example:

```powershell
python -m serial.tools.miniterm COM6 115200
```

Serial settings:

```text
115200 baud
8 data bits
no parity
1 stop bit
no flow control
```

On first boot, log in using the PetaLinux user and complete any first-login
password setup requested by the generated image.

---

# 20. Ethernet and SSH

The verified development setup uses a direct host-to-Zybo Ethernet connection.

The Zybo root filesystem is configured with:

```text
192.168.10.2/24
```

Configure the directly connected Windows Ethernet adapter with:

```text
192.168.10.1/24
```

Identify the adapter:

```powershell
Get-NetAdapter
```

Example configuration:

```powershell
$ETH_ALIAS = "Ethernet 4"

New-NetIPAddress `
  -InterfaceAlias $ETH_ALIAS `
  -IPAddress 192.168.10.1 `
  -PrefixLength 24
```

Check reachability:

```powershell
ping 192.168.10.2
```

After replacing the root filesystem, the SSH host key may change.

Remove an old cached key if required:

```powershell
ssh-keygen -R 192.168.10.2
```

Connect:

```powershell
ssh petalinux@192.168.10.2
```

---

# 21. Verify the AES driver on the board

After Linux boots, verify that the AES accelerator device exists:

```bash
ls -l /dev/zybo_aes_ctr0
```

The final AES image uses:

```text
/dev/zybo_aes_ctr0
```

This is the device used by the validation and benchmark applications.

---

# 22. Run AES functional validation

Run:

```bash
sudo zybo-aes-ctr-test
```

This application exercises the AES-CTR accelerator through the final Linux
driver and DMA data path.

The validation must complete without reported failures.

---

# 23. Run the benchmark

Run:

```bash
sudo zybo-aes-ctr-bench
```

The final benchmark covers transfer sizes from small messages through the
1 MiB maximum transfer policy used by the driver.

For the final verified 1 MiB measurement:

```text
FPGA AES-CTR throughput : 32.087 MiB/s
CPU AES-CTR throughput  : 3.257 MiB/s
Speedup                 : approximately 9.85x
```

The benchmark validates output correctness while comparing FPGA and CPU
execution.

---

# 24. Clean rebuild verification status

The public repository reconstruction flow has been verified through a clean
build using the repository-controlled inputs.

The verified clean-build sequence was:

1. A fresh Zynq PetaLinux project was created.
2. `zybo_z7_20_aes_ctr_integration.xsa` was imported.
3. The pinned platform `project-spec` snapshot was applied.
4. The AES-specific `project-spec` overlay was applied.
5. `petalinux-config --silentconfig` completed successfully.
6. `petalinux-config -c rootfs --silentconfig` completed successfully.
7. `petalinux-build` completed successfully.
8. The final image manifest contained:
   - the AES kernel-module package
   - `zybo-aes-ctr-accel`
   - `zybo-aes-ctr-test`
   - `zybo-aes-ctr-bench`
9. The final compiled DTB contained the required `tx` and `rx` DMA channel
   binding.

The final AES-CTR hardware/software system has also been functionally tested on
the Zybo Z7-20.

The clean PetaLinux rebuild verification described above establishes that the
committed public repository inputs reproduce the intended Linux integration.
Board deployment of generated images can then follow the deployment procedure
in this guide.

---

# 25. Repeatable notes

## PetaLinux project creation warning

PetaLinux 2025.2 may print a deprecation message for:

```text
petalinux-create -t project
```

The command is still accepted by the verified 2025.2 tool installation.

## TFTP warning

Messages such as:

```text
Failed to copy built images to tftp dir: /tftpboot
```

do not affect this SD-card deployment workflow.

## SSH host-key changes

A newly generated root filesystem may produce a new SSH host key.

Clear the previous Windows entry with:

```powershell
ssh-keygen -R 192.168.10.2
```

Then reconnect normally.

