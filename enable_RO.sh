#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Enable NVIDIA PCIe Relaxed Ordering and reload the NVIDIA driver immediately.

set -Eeuo pipefail

CONFIG_FILE="/etc/modprobe.d/nvidia-relaxed-ordering.conf"
TARGET_VALUE=1
ACTION="enable"

STOPPED_SERVICES=()

log() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        die "This script must run as root. Try: sudo $0"
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

module_loaded() {
    [[ -d "/sys/module/$1" ]]
}

show_device_users() {
    local devices=(/dev/nvidia*)

    if [[ ${#devices[@]} -eq 0 || ! -e ${devices[0]} ]]; then
        log "No /dev/nvidia* device files found."
        return 0
    fi

    fuser -v "${devices[@]}" 2>&1 || true
}

write_config() {
    local config_dir
    local tmp_file
    local backup_file

    config_dir="$(dirname "${CONFIG_FILE}")"
    mkdir -p "${config_dir}"

    if [[ ! -e "${CONFIG_FILE}" ]]; then
        install -m 0644 /dev/null "${CONFIG_FILE}"
        log "Created ${CONFIG_FILE}"
    fi

    backup_file="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${CONFIG_FILE}" "${backup_file}"
    log "Backed up ${CONFIG_FILE} to ${backup_file}"

    tmp_file="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")"

    awk -v value="${TARGET_VALUE}" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }

        /^[[:space:]]*#/ || $0 !~ /^[[:space:]]*options[[:space:]]+nvidia([[:space:]]|$)/ || $0 !~ /NVreg_EnablePCIERelaxedOrderingMode[[:space:]]*=/ {
            print
            next
        }

        {
            line = $0
            gsub(/[[:space:]]+NVreg_EnablePCIERelaxedOrderingMode[[:space:]]*=[^[:space:]]+/, "", line)
            gsub(/NVreg_EnablePCIERelaxedOrderingMode[[:space:]]*=[^[:space:]]+[[:space:]]*/, "", line)
            line = trim(line)
            if (line !~ /^options[[:space:]]+nvidia[[:space:]]*$/) {
                print line
            }
        }

        END {
            print "options nvidia NVreg_EnablePCIERelaxedOrderingMode=" value
        }
    ' "${CONFIG_FILE}" > "${tmp_file}"

    install -m 0644 "${tmp_file}" "${CONFIG_FILE}"
    rm -f "${tmp_file}"
    log "Set NVreg_EnablePCIERelaxedOrderingMode=${TARGET_VALUE} in ${CONFIG_FILE}"
}

print_status() {
    printf '## Config file: %s\n' "${CONFIG_FILE}"
    grep -nE 'NVreg_EnablePCIERelaxedOrderingMode|NVreg_RegistryDwords' "${CONFIG_FILE}" || true

    printf '\n## live NVIDIA params\n'
    if [[ -r /proc/driver/nvidia/params ]]; then
        grep -Ei 'EnablePCIERelaxedOrderingMode|RegistryDwords|EnablePCIe' /proc/driver/nvidia/params || true
    else
        printf 'NVIDIA driver is not loaded or /proc/driver/nvidia/params is not readable.\n'
    fi
}

collect_active_services() {
    local service
    local candidates=(
        gdm.service
        display-manager.service
        sddm.service
        lightdm.service
        nvidia-persistenced.service
        nvidia-fabricmanager.service
        nvidia-dcgm.service
        dcgm.service
        nvidia-imex.service
    )

    STOPPED_SERVICES=()
    for service in "${candidates[@]}"; do
        if systemctl is-active --quiet "${service}" 2>/dev/null; then
            STOPPED_SERVICES+=("${service}")
        fi
    done
}

stop_active_services() {
    local service

    collect_active_services
    if [[ ${#STOPPED_SERVICES[@]} -eq 0 ]]; then
        log "No known display/NVIDIA services need to be stopped."
        return 0
    fi

    log "Stopping services: ${STOPPED_SERVICES[*]}"
    for service in "${STOPPED_SERVICES[@]}"; do
        systemctl stop "${service}" || warn "Failed to stop ${service}"
    done
}

restart_stopped_services() {
    local service
    local i

    if [[ ${#STOPPED_SERVICES[@]} -eq 0 ]]; then
        return 0
    fi

    log "Restarting services that were active before reload."
    for ((i = ${#STOPPED_SERVICES[@]} - 1; i >= 0; i--)); do
        service="${STOPPED_SERVICES[$i]}"
        systemctl start "${service}" || warn "Failed to start ${service}"
    done

    STOPPED_SERVICES=()
}

cleanup() {
    local status=$?
    trap - EXIT

    if [[ ${status} -ne 0 && ${#STOPPED_SERVICES[@]} -gt 0 ]]; then
        warn "Script failed; attempting to restore stopped services."
        restart_stopped_services || true
    fi

    exit "${status}"
}

terminate_device_users() {
    local devices=(/dev/nvidia*)

    if [[ ${#devices[@]} -eq 0 || ! -e ${devices[0]} ]]; then
        return 0
    fi

    if ! fuser -s "${devices[@]}" 2>/dev/null; then
        log "No remaining /dev/nvidia* users."
        return 0
    fi

    warn "Processes are still using NVIDIA device files:"
    show_device_users

    log "Sending SIGTERM to remaining /dev/nvidia* users."
    fuser -TERM -k "${devices[@]}" 2>/dev/null || true
    sleep 2

    if fuser -s "${devices[@]}" 2>/dev/null; then
        warn "Some processes are still using /dev/nvidia*; sending SIGKILL."
        fuser -KILL -k "${devices[@]}" 2>/dev/null || true
    fi
}

unload_nvidia_modules() {
    local module
    local loaded_modules=()
    local unload_order=(
        nvidia_peermem
        nvidia_uvm
        nvidia_drm
        nvidia_modeset
        nvidia
    )

    for module in "${unload_order[@]}"; do
        if module_loaded "${module}"; then
            loaded_modules+=("${module}")
        fi
    done

    if [[ ${#loaded_modules[@]} -eq 0 ]]; then
        log "No NVIDIA modules are currently loaded."
        return 0
    fi

    log "Unloading modules: ${loaded_modules[*]}"
    if ! modprobe -r "${loaded_modules[@]}"; then
        warn "Failed to unload NVIDIA modules. Current users/modules:"
        show_device_users
        lsmod | grep -E '^(nvidia|nvidia_drm|nvidia_modeset|nvidia_uvm|nvidia_peermem)' || true
        die "Could not unload NVIDIA modules."
    fi
}

load_nvidia_modules() {
    local module
    local load_order=(
        nvidia
        nvidia_uvm
        nvidia_modeset
        nvidia_drm
    )

    for module in "${load_order[@]}"; do
        if modinfo "${module}" >/dev/null 2>&1; then
            log "Loading ${module}"
            modprobe "${module}"
        fi
    done
}

verify_live_value() {
    local live_value

    if [[ ! -r /proc/driver/nvidia/params ]]; then
        die "/proc/driver/nvidia/params is not readable after loading NVIDIA modules."
    fi

    live_value="$(awk -F': ' '/^EnablePCIERelaxedOrderingMode:/ { print $2 }' /proc/driver/nvidia/params)"
    if [[ "${live_value}" != "${TARGET_VALUE}" ]]; then
        print_status
        die "Expected EnablePCIERelaxedOrderingMode=${TARGET_VALUE}, got ${live_value:-unknown}."
    fi

    log "Verified live EnablePCIERelaxedOrderingMode=${live_value}"
}

reload_driver() {
    log "GPU/NVIDIA users before reload:"
    show_device_users

    stop_active_services
    terminate_device_users
    unload_nvidia_modules
    load_nvidia_modules
    verify_live_value
    restart_stopped_services
}

main() {
    if [[ $# -ne 0 ]]; then
        die "This script does not take arguments. Run: sudo $0"
    fi

    require_root
    require_command awk
    require_command cp
    require_command date
    require_command fuser
    require_command grep
    require_command install
    require_command mktemp
    require_command modinfo
    require_command modprobe
    require_command systemctl

    trap cleanup EXIT

    log "Will ${ACTION} NVIDIA PCIe Relaxed Ordering and reload the driver now."
    write_config
    reload_driver
    print_status
}

main "$@"