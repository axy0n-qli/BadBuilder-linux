#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'
GREEN='\033[0;32m'
DKGREEN='\033[0;32m'
ORANGE='\033[38;5;208m'
YELLOW='\033[1;33m'
GRAY='\033[0;90m'
BOLD='\033[1m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/Work"
DOWNLOAD_DIR="${WORK_DIR}/Downloads"
STAGING_DIR="${WORK_DIR}/Staging"

CONTENT_URL="https://archive.org/download/abapendrive.-7z/ABApendrive.7z"
REPO_URL="https://github.com/axy0n-qli/BadBuilder-linux"

TARGET_DISK_ID=""
TARGET_DISK_NAME=""
TARGET_DISK_SIZE_GB=""
TARGET_DISK_PATH=""
MOUNT_POINT=""

cleanup() {
    if [[ -n "$MOUNT_POINT" ]] && mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        sync
        umount "$MOUNT_POINT" 2>/dev/null || true
        rmdir "$MOUNT_POINT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

render_header() {
    clear
    echo -e "${DKGREEN}██████╗  █████╗ ██████╗ ██████╗ ██╗   ██╗██╗██╗     ██████╗ ███████╗██████╗${RESET}"
    echo -e "${DKGREEN}██╔══██╗██╔══██╗██╔══██╗██╔══██╗██║   ██║██║██║     ██╔══██╗██╔════╝██╔══██╗${RESET}"
    echo -e "${GREEN}██████╔╝███████║██║  ██║██████╔╝██║   ██║██║██║     ██║  ██║█████╗  ██████╔╝${RESET}"
    echo -e "${GREEN}██╔══██╗██╔══██║██║  ██║██╔══██╗██║   ██║██║██║     ██║  ██║██╔══╝  ██╔══██╗${RESET}"
    echo -e "${GREEN}██████╔╝██║  ██║██████╔╝██████╔╝╚██████╔╝██║███████╗██████╔╝███████╗██║  ██║${RESET}"
    echo -e "${GREEN}╚═════╝ ╚═╝  ╚═╝╚═════╝ ╚═════╝  ╚═════╝ ╚═╝╚══════╝╚═════╝ ╚══════╝╚═╝  ╚═╝${RESET}"
    echo ""
    echo -e "${GREEN}──────────────────────────────────────────────────────────v3.0.0${RESET}"
    echo -e "────────────────────Xbox 360 ${ORANGE}BadUpdate${RESET} USB Builder──────────────────────"
    echo -e "                          ${GRAY}Created by Pdawg | Fork raphaelmaria${RESET}"
    echo -e "${GREEN}──────────────────────────────────────────────────────────────────────${RESET}"
    echo ""
}

show_summary() {
    echo -e "┌──────────────────────────────────────────────────────────┐"
    printf  "│  %-16s  %-38s│\n" "Drive" \
        "${TARGET_DISK_NAME:-None selected} ${TARGET_DISK_PATH:+($TARGET_DISK_PATH)}"
    printf  "│  %-16s  %-38s│\n" "Source" "archive.org/ABApendrive"
    echo -e "└──────────────────────────────────────────────────────────┘"
    echo ""
}

msg_info()  { echo -e "${YELLOW}[*]${RESET} $*" >&2; }
msg_ok()    { echo -e "${GREEN}[+]${RESET} $*" >&2; }
msg_warn()  { echo -e "${ORANGE}[!]${RESET} $*" >&2; }
msg_err()   { echo -e "${RED}[-]${RESET} $*" >&2; }

pause() {
    local msg="${1:-Press Enter to continue...}"
    echo -e "\n${GRAY}${msg}${RESET}"
    read -r _
}

prompt_menu() {
    local title="$1"; shift
    local options=("$@")
    echo ""
    echo -e "${ORANGE}${BOLD}${title}${RESET}"
    for i in "${!options[@]}"; do
        echo -e "  ${GREEN}$((i+1))${RESET}. ${options[$i]}"
    done
    echo ""
    while true; do
        read -rp "Select [1-${#options[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            REPLY_INDEX=$(( choice - 1 ))
            return 0
        fi
        echo -e "${RED}Invalid option.${RESET}"
    done
}

confirm() {
    while true; do
        read -rp "${1} [y/N]: " yn
        case "${yn,,}" in
            y|yes) return 0 ;;
            n|no|"") return 1 ;;
        esac
    done
}

check_deps() {
    local missing=()
    for cmd in lsblk parted mkfs.fat mount umount curl jq 7z; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        msg_err "Missing dependencies:"
        for dep in "${missing[@]}"; do echo "    - $dep"; done
        echo ""
        echo "Debian/Ubuntu: sudo apt install util-linux dosfstools parted curl jq p7zip-full"
        echo "Fedora/RHEL:   sudo dnf install util-linux dosfstools parted curl jq p7zip p7zip-plugins"
        exit 1
    fi
}

list_disks() {
    lsblk -J -d -b -o NAME,SIZE,TYPE,TRAN,MODEL,RM 2>/dev/null | \
    jq -r '.blockdevices[] |
        select(.type == "disk") |
        select(.name | test("^loop|^sr|^fd"; "i") | not) |
        [
          .name,
          (.model // .name | ltrimstr(" ") | rtrimstr(" ")),
          ((.size // 0) | tonumber / 1073741824 | . * 100 | round / 100 | tostring),
          (if .rm == true or .rm == 1 or (.rm | tostring) == "1" or .tran == "usb" then "Removable" else "Fixed" end),
          ("/dev/" + .name)
        ] | join("|")'
}

umount_partitions() {
    local dev="$1"
    local devname; devname="$(basename "$dev")"
    [[ -f /proc/mounts ]] || return 0
    while IFS=' ' read -r mdev mpoint _rest; do
        local mname; mname="$(basename "$mdev")"
        if [[ "$mname" == "${devname}"* && "$mname" != "$devname" ]]; then
            umount "$mdev" 2>/dev/null || true
        fi
    done < /proc/mounts
}

format_fat32() {
    local dev="$1"
    local devname; devname="$(basename "$dev")"

    msg_info "Unmounting partitions on $dev..."
    umount_partitions "$dev"

    msg_info "Writing partition table..."
    parted -s "$dev" mklabel msdos
    parted -s "$dev" mkpart primary fat32 1MiB 100%
    parted -s "$dev" set 1 lba on

    partprobe "$dev" 2>/dev/null || blockdev --rereadpt "$dev" 2>/dev/null || true
    udevadm settle 2>/dev/null || sleep 2

    local part=""
    for _try in $(seq 1 10); do
        if   [[ -b "${dev}1"  ]]; then part="${dev}1";  break
        elif [[ -b "${dev}p1" ]]; then part="${dev}p1"; break
        fi
        sleep 0.5
    done
    [[ -n "$part" ]] || { msg_err "Partition ${dev}1 did not appear."; exit 1; }

    msg_info "Formatting $part as FAT32..."
    mkfs.fat -F 32 -n "BADUPDATE" "$part"

    MOUNT_POINT="/tmp/badbuilder_${devname}"
    umount "$MOUNT_POINT" 2>/dev/null || true
    mkdir -p "$MOUNT_POINT"
    mount "$part" "$MOUNT_POINT"
    msg_ok "Drive formatted and mounted at $MOUNT_POINT"
}

first_subdir() {
    find "$1" -mindepth 1 -maxdepth 1 -type d | sort | head -1
}

copy_dir_contents() {
    local src="$1" dst="$2"
    [[ -d "$src" ]] || { msg_err "Source directory not found: $src"; exit 1; }
    mkdir -p "$dst"
    cp -r "$src"/. "$dst"/
}

eject_drive() {
    local dev="$1"
    local mnt="$2"

    msg_info "Syncing data to disk..."
    sync

    msg_info "Unmounting the USB drive..."
    umount "$mnt" 2>/dev/null || true
    rmdir  "$mnt" 2>/dev/null || true
    MOUNT_POINT=""

    if command -v udisksctl &>/dev/null; then
        udisksctl power-off -b "$dev" 2>/dev/null && return
    fi
    if command -v eject &>/dev/null; then
        eject "$dev" 2>/dev/null && return
    fi
}

check_update() {
    [[ "${BADBUILDER_UPDATED:-0}" == "1" ]] && return 0
    [[ -f "${SCRIPT_DIR}/update.sh" ]] || return 0

    local rc=0
    bash "${SCRIPT_DIR}/update.sh" || rc=$?

    if (( rc == 10 )); then
        msg_ok "Restarting BadBuilder with the new version..."
        sleep 2
        export BADBUILDER_UPDATED=1
        exec bash "${SCRIPT_DIR}/BadBuilder.sh" "$@"
    fi
    sleep 1
}

download_file() {
    local url="$1" dest="$2"
    local final_url

    msg_info "Downloading: ${url}"
    if ! final_url="$(curl -fL --retry 3 --progress-bar -o "$dest" -w '%{url_effective}' "$url")"; then
        msg_err "Download failed for ${url}. Check your internet connection."
        return 1
    fi
    if [[ -n "$final_url" && "$final_url" != "$url" ]]; then
        msg_info "Redirected to: ${final_url}"
    fi
    msg_ok "Download complete: ${dest}"
}

download_usb_content() {
    local usb="$1"
    local archive_file="${DOWNLOAD_DIR}/ABApendrive.7z"
    local stage="${STAGING_DIR}/usb"
    mkdir -p "$DOWNLOAD_DIR" "$STAGING_DIR"

    msg_info "Downloading USB drive content..."
    download_file "$CONTENT_URL" "$archive_file" || exit 1

    msg_info "Extracting files..."
    rm -rf "$stage"
    mkdir -p "$stage"
    if ! 7z x "$archive_file" -o"$stage" -y > /dev/null; then
        msg_err "Failed to extract the archive. The download may be corrupted."
        exit 1
    fi

    local root_dir; root_dir="$(first_subdir "$stage")"
    local src_dir="$stage"; [[ -n "$root_dir" ]] && src_dir="$root_dir"

    msg_ok "Copying files to the USB drive..."
    copy_dir_contents "$src_dir" "$usb"
    rm -rf "$stage"
}

menu_configure_drive() {
    render_header
    msg_info "Scanning disks..."
    local disk_lines=()
    while IFS= read -r line; do
        disk_lines+=("$line")
    done < <(list_disks)

    if [[ ${#disk_lines[@]} -eq 0 ]]; then
        msg_err "No disks found."
        pause; return
    fi

    local labels=()
    for line in "${disk_lines[@]}"; do
        IFS='|' read -r did dname dsize dtype dpath <<< "$line"
        labels+=("${dname} (${dsize} GB) - ${dtype} [${dpath}]")
    done
    labels+=("Back")

    prompt_menu "Select the target drive  [ALL DATA WILL BE ERASED]" "${labels[@]}"

    if (( REPLY_INDEX == ${#disk_lines[@]} )); then return; fi

    IFS='|' read -r TARGET_DISK_ID TARGET_DISK_NAME TARGET_DISK_SIZE_GB _ TARGET_DISK_PATH \
        <<< "${disk_lines[$REPLY_INDEX]}"
    msg_ok "Selecionado: ${TARGET_DISK_NAME} (${TARGET_DISK_PATH})"
    pause
}

menu_install() {
    render_header
    show_summary

    if [[ -z "$TARGET_DISK_PATH" ]]; then
        msg_err "No drive selected."
        pause; return
    fi

    echo -e "${ORANGE}${BOLD}WARNING:${RESET} All data on ${TARGET_DISK_NAME} (${TARGET_DISK_PATH}) will be erased."
    if ! confirm "Confirm formatting of ${TARGET_DISK_PATH}?"; then
        return
    fi

    echo ""

    format_fat32 "$TARGET_DISK_PATH"
    echo ""

    download_usb_content "$MOUNT_POINT"
    echo ""

    echo "USB Storage Device" > "${MOUNT_POINT}/name.txt"
    {
        echo "This drive was created with BadBuilder by Pdawg."
        echo "${REPO_URL}"
        echo ""
        echo "Source: ${CONTENT_URL}"
        echo "Drive:  ${TARGET_DISK_NAME} (${TARGET_DISK_PATH})"
    } > "${MOUNT_POINT}/info.txt"

    local _dev="$TARGET_DISK_PATH"
    local _mnt="$MOUNT_POINT"
    eject_drive "$_dev" "$_mnt"

    echo ""
    echo -e "${GREEN}┌──────────────────────────────────────────────────────────────┐${RESET}"
    echo -e "${GREEN}│                                                              │${RESET}"
    echo -e "${GREEN}│   ✓  PROCESS COMPLETED SUCCESSFULLY!                         │${RESET}"
    echo -e "${GREEN}│                                                              │${RESET}"
    echo -e "${GREEN}│   The USB drive is ready to use on your Xbox 360.            │${RESET}"
    echo -e "${GREEN}│   The device has been unmounted. You can safely              │${RESET}"
    echo -e "${GREEN}│   remove it from the computer.                               │${RESET}"
    echo -e "${GREEN}│                                                              │${RESET}"
    printf  "${GREEN}│   Drive: %-52s│${RESET}\n" "$_dev"
    echo -e "${GREEN}│                                                              │${RESET}"
    echo -e "${GREEN}└──────────────────────────────────────────────────────────────┘${RESET}"
    echo ""
    pause "Press Enter to exit..."
    exit 0
}

main() {
    if (( EUID != 0 )); then
        echo "This script must be run as root (sudo)."
        exit 1
    fi

    check_update "$@"
    check_deps
    mkdir -p "$DOWNLOAD_DIR" "$STAGING_DIR"

    while true; do
        render_header
        show_summary

        prompt_menu "Select an action" \
            "Target drive" \
            "Install" \
            "Exit"

        case $REPLY_INDEX in
            0) menu_configure_drive ;;
            1) menu_install ;;
            2) exit 0 ;;
        esac
    done
}

main "$@"
