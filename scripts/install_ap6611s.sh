#!/usr/bin/env bash
set -euo pipefail

info() {
    printf '\033[1;32m[INFO]\033[0m %s\n' "$*"
}
warn() {
    printf '\033[1;33m[WARN]\033[0m %s\n' "$*"
}
error() {
    printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
}

if [[ "$(id -u)" -ne 0 ]]; then
    error "This script must be run as root to install modules and trigger depmod."
    exit 1
fi

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
# Default to a build directory inside the repository to avoid /tmp permission issues
WORKDIR=${WORKDIR:-"${SCRIPT_DIR}/../ap6611s-build"}
PATCH_SCRIPT=${PATCH_SCRIPT:-/home/pi/ap6611s-support/generate_patch.sh}
PATCH_FILE=${PATCH_FILE:-/home/pi/repo/patches/ap6611s-brcmfmac.patch}
DTB_TARGETS=${DTB_TARGETS:-"rk3588-orangepi-5-max.dtb rk3588-orangepi-5-plus.dtb rk3588-orangepi-5-ultra.dtb"}
DTB_DEST_DIR=${DTB_DEST_DIR:-/boot/dtb/rockchip}
KERNEL_SHORT=${KERNEL_SHORT:-6.18.3}
#TARBALL_URL=https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_SHORT}.tar.xz
TARBALL_URL=${TARBALL_URL:-https://mirrors.aliyun.com/linux-kernel/v6.x/linux-${KERNEL_SHORT}.tar.xz}
TARBALL=${WORKDIR}/linux-${KERNEL_SHORT}.tar.xz
SRC_DIR=${WORKDIR}/linux-${KERNEL_SHORT}
MOD_SRC=drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko
MOD_DST=/lib/modules/$(uname -r)/kernel/drivers/net/wireless/broadcom/brcm80211/brcmfmac/brcmfmac.ko

mkdir -p "$WORKDIR"

# Temporary files state (populated later)
DTBS_LIST_PATH=""
DTBS_LIST_BACKUP=""

cleanup() {
    exit_code=${1:-$?}
    # Restore dtbs-list if we created a backup
    if [[ -n "$DTBS_LIST_BACKUP" && -f "$DTBS_LIST_BACKUP" ]]; then
        mv -f "$DTBS_LIST_BACKUP" "$DTBS_LIST_PATH" || true
        warn "Restored original dtbs-list from $DTBS_LIST_BACKUP"
    elif [[ -n "$DTBS_LIST_PATH" && -f "$DTBS_LIST_PATH" ]]; then
        # Remove temporary dtbs-list if we created one and no backup exists
        rm -f "$DTBS_LIST_PATH" || true
        warn "Removed temporary dtbs-list $DTBS_LIST_PATH"
    fi

    if [[ "$exit_code" -ne 0 ]]; then
        echo "❌ Script exited abnormally"
    fi
    exit "$exit_code"
}

trap 'cleanup $?' EXIT INT TERM QUIT

info "Ensuring build dependencies are installed"
if ! apt-get update >/dev/null 2>&1; then
    warn "apt-get update failed; continuing with existing package lists"
fi
apt-get install -y --no-install-recommends bc build-essential libncurses-dev bison flex libssl-dev libelf-dev ccache wget make patch device-tree-compiler >/dev/null

if [[ ! -f "$PATCH_FILE" || ! -s "$PATCH_FILE" ]]; then
    if [[ -x "$PATCH_SCRIPT" ]]; then
        info "Generating patch file"
        "$PATCH_SCRIPT"
    else
        error "Missing patch script $PATCH_SCRIPT or patch file $PATCH_FILE"
        exit 1
    fi
fi

if [[ ! -f "$TARBALL" ]]; then
    info "Downloading kernel ${KERNEL_SHORT}"
    wget -nv -O "$TARBALL" "$TARBALL_URL"
fi

if [[ ! -d "$SRC_DIR" ]]; then
    info "Extracting kernel source to $SRC_DIR"
    tar -xf "$TARBALL" -C "$WORKDIR"
    # Ensure extracted files are owned by the invoking non-root user to avoid
    # permission problems when later editing or building as that user.
    # Prefer SUDO_USER if available, otherwise fall back to whoami (should be root).
    INVOKER_USER=${SUDO_USER:-$(whoami)}
    if id "$INVOKER_USER" >/dev/null 2>&1; then
        info "Setting ownership of $SRC_DIR to $INVOKER_USER"
        chown -R "$INVOKER_USER":"$INVOKER_USER" "$SRC_DIR" || \
            warn "chown failed; you may need to fix permissions manually"
    else
        warn "Invoker user $INVOKER_USER not found; skipping chown"
    fi
fi

cd "$SRC_DIR"
if [[ -f "/boot/config-$(uname -r)" ]]; then
    info "Copying running kernel config"
    cp "/boot/config-$(uname -r)" .config
else
    warn "/boot/config-$(uname -r) not found; using default config"
fi
# Try to run olddefconfig; if the target is unavailable (some extracted trees
# or minimal tarballs may not provide it), fall back to a safe alternative.
if make olddefconfig >/dev/null 2>&1; then
    info "make olddefconfig succeeded"
else
    warn "make olddefconfig failed; falling back to 'make defconfig'"
    if make defconfig >/dev/null 2>&1; then
        info "make defconfig succeeded"
    else
        warn "make defconfig also failed; continuing without full config (some build steps may fail)"
    fi
fi
# Prepare modules (best-effort)
if make modules_prepare >/dev/null 2>&1; then
    info "make modules_prepare succeeded"
else
    warn "make modules_prepare failed; module builds may still work against host build tree"
fi

HOST_SYMVERS="/lib/modules/$(uname -r)/build/Module.symvers"
if [[ -f "$HOST_SYMVERS" ]]; then
    info "Copying host Module.symvers"
    cp "$HOST_SYMVERS" "$SRC_DIR/Module.symvers"
else
    warn "Host Module.symvers not found; modpost may fail"
fi

info "Applying AP6611S patch"
if patch -p1 < "$PATCH_FILE"; then
    info "Patch applied cleanly"
else
    warn "Patch did not apply cleanly; continuing (it may already be applied)"
fi

info "Building brcmfmac module against running kernel build tree"
# Build the module against the running kernel's build directory so vermagic matches
if [[ -d "/lib/modules/$(uname -r)/build" ]]; then
    make -C "/lib/modules/$(uname -r)/build" M="$SRC_DIR/drivers/net/wireless/broadcom/brcm80211/brcmfmac" modules -j"$(nproc)"
else
    info "/lib/modules/$(uname -r)/build not found; falling back to in-tree build"
    make M=drivers/net/wireless/broadcom/brcm80211/brcmfmac -j"$(nproc)"
fi

if [[ ! -f "$SRC_DIR/$MOD_SRC" ]]; then
    error "Module build failed: $MOD_SRC not found"
    exit 1
fi

info "Building device trees (only requested targets: $DTB_TARGETS)"
# Create a temporary dtbs-list in arch/$(SRCARCH)/boot/dts so that 'make dtbs'
# will only build the requested DTBs. Back up existing file if present.
DTBS_LIST_PATH="${SRC_DIR}/arch/arm64/boot/dts/dtbs-list"
DTBS_LIST_BACKUP=""
if [[ -f "$DTBS_LIST_PATH" ]]; then
    DTBS_LIST_BACKUP="${DTBS_LIST_PATH}.ap6611s.bak"
    cp -a "$DTBS_LIST_PATH" "$DTBS_LIST_BACKUP"
fi
printf '%s
' $DTB_TARGETS > "$DTBS_LIST_PATH"
if make -C "$SRC_DIR" ARCH=arm64 dtbs -j"$(nproc)" >/tmp/ap6611s-dtbs.log 2>&1; then
    info "Requested DTBs built successfully (log: /tmp/ap6611s-dtbs.log)"
else
    warn "DTB build failed; see /tmp/ap6611s-dtbs.log for details"
    # Restore original dtbs-list if it existed
    if [[ -n "$DTBS_LIST_BACKUP" ]]; then
        mv -f "$DTBS_LIST_BACKUP" "$DTBS_LIST_PATH" || true
    else
        rm -f "$DTBS_LIST_PATH" || true
    fi
    error "Aborting due to DTB build failure"
    exit 1
fi
# dtbs-list cleanup is handled by cleanup()/trap

info "Installing device trees"
mkdir -p "$DTB_DEST_DIR"
for dtb in $DTB_TARGETS; do
    dtb_name=$(basename "$dtb")
    DTB_SRC="$SRC_DIR/arch/arm64/boot/dts/rockchip/$dtb_name"
    if [[ ! -f "$DTB_SRC" ]]; then
        warn "$dtb_name not found at $DTB_SRC"
        continue
    fi
    DTB_DEST="$DTB_DEST_DIR/$dtb_name"
    if [[ -f "$DTB_DEST" && ! -f "$DTB_DEST.ap6611s.bak" ]]; then
        cp "$DTB_DEST" "$DTB_DEST.ap6611s.bak"
    fi
    install -m 0644 "$DTB_SRC" "$DTB_DEST"
    info "Replaced $dtb at $DTB_DEST"
done

if [[ -f "$MOD_DST" ]]; then
    if [[ ! -f "$MOD_DST.ap6611s.bak" ]]; then
        cp "$MOD_DST" "$MOD_DST.ap6611s.bak"
    fi
else
    warn "Existing brcmfmac module not found at $MOD_DST"
fi

info "Installing new module"
install -m 0644 "$SRC_DIR/$MOD_SRC" "$MOD_DST"
depmod -a >/dev/null
if modprobe -r brcmfmac; then
    info "Old module unloaded"
else
    warn "brcmfmac was not loaded before install"
fi
if modprobe brcmfmac; then
    info "brcmfmac module replaced; monitor dmesg for POST events"
else
    warn "New brcmfmac module installed; modprobe failed, load manually"
fi

info "Done"
