#!/usr/bin/env bash
set -euo pipefail

# Compose a lean i3status config suited to this machine
config_dir="${HOME}/.config/i3"
generated_config="$(mktemp "${config_dir}/i3status.generated.XXXXXX")"

# Let hosts set custom interface names
wired_iface="${STATUS_WIRED_IFACE:-enp3s0}"
wireless_iface="${STATUS_WIRELESS_IFACE:-wlan0}"

child_pid=""

cleanup() {
    if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
        kill -TERM "$child_pid"
        wait "$child_pid" 2>/dev/null || true
    fi
    rm -f "$generated_config"
}
trap cleanup EXIT

interface_exists() {
    local iface="$1"
    if [ -z "$iface" ]; then
        return 1
    fi
    if ip link show "$iface" &>/dev/null; then
        return 0
    fi
    return 1
}

find_battery_device() {
    local power_path=""
    for power_path in /sys/class/power_supply/*; do
        [ -d "$power_path" ] || continue
        if [ -f "$power_path/type" ]; then
            local type=""
            if ! type=$(cat "$power_path/type"); then
                continue
            fi
            if [ "$type" = "Battery" ]; then
                basename "$power_path"
                return 0
            fi
        fi
    done
    return 1
}

find_temperature_path() {
    local zone=""
    for zone in /sys/class/thermal/thermal_zone*; do
        [ -d "$zone" ] || continue
        local type_file="$zone/type"
        local temp_file="$zone/temp"
        if [ -f "$type_file" ] && [ -f "$temp_file" ]; then
            local zone_type=""
            if ! zone_type=$(cat "$type_file"); then
                continue
            fi
            case "$zone_type" in
                x86_pkg_temp|cpu_thermal|soc_thermal|acpitz|k10temp|pch_cannonlake)
                    printf '%s' "$temp_file"
                    return 0
                    ;;
            esac
        fi
    done

    local hwmon=""
    for hwmon in /sys/class/hwmon/hwmon*; do
        [ -d "$hwmon" ] || continue
        local name_file="$hwmon/name"
        [ -f "$name_file" ] || continue
        local hwmon_name=""
        if ! hwmon_name=$(cat "$name_file"); then
            continue
        fi

        local input=""
        case "$hwmon_name" in
            coretemp|k10temp|zenpower|cpu_thermal|soc_thermal)
                for input in "$hwmon"/temp*_input; do
                    [ -f "$input" ] || continue
                    printf '%s' "$input"
                    return 0
                done
                ;;
            *)
                for input in "$hwmon"/temp*_input; do
                    [ -f "$input" ] || continue
                    local label_file="${input%_input}_label"
                    if [ -f "$label_file" ]; then
                        local label=""
                        if ! label=$(cat "$label_file"); then
                            continue
                        fi
                        case "$label" in
                            *CPU*|*Tctl*|*Package*)
                                printf '%s' "$input"
                                return 0
                                ;;
                        esac
                    fi
                done
                ;;
        esac
    done
    return 1
}

generate_config() {
    local battery_device=""
    if battery_device=$(find_battery_device); then
        :
    else
        battery_device=""
    fi

    local temperature_path=""
    if temperature_path=$(find_temperature_path); then
        :
    else
        temperature_path=""
    fi

    local have_wired=0
    if interface_exists "$wired_iface"; then
        have_wired=1
    fi

    local have_wireless=0
    if interface_exists "$wireless_iface"; then
        have_wireless=1
    fi

    {
        if [ "$have_wired" -eq 1 ]; then
            echo "order += \"ethernet ${wired_iface}\""
        fi
        if [ "$have_wireless" -eq 1 ]; then
            echo "order += \"wireless ${wireless_iface}\""
        fi
        if [ -n "$battery_device" ]; then
            echo "order += \"battery main\""
        fi
        echo "order += \"cpu_usage\""
        if [ -n "$temperature_path" ]; then
            echo "order += \"cpu_temperature core\""
        fi
        echo "order += \"disk /\""
        echo "order += \"tztime local\""
        echo ""

        if [ "$have_wireless" -eq 1 ]; then
            cat <<EOF
wireless ${wireless_iface} {
    format_up = "%ip"
    format_down = ""
}

EOF
        fi

        if [ "$have_wired" -eq 1 ]; then
            cat <<EOF
ethernet ${wired_iface} {
    format_up = "%ip"
    format_down = ""
}

EOF
        fi

        cat <<'EOF'
tztime local {
    format = " %Y-%m-%d %a  %H:%M:%S"
}

cpu_usage {
    format = " %usage"
}
EOF
        echo ""

        if [ -n "$temperature_path" ]; then
            cat <<EOF
cpu_temperature core {
    format = " %degrees°C"
    path = "$temperature_path"
}

EOF
        fi

        cat <<'EOF'
disk "/" {
    format = " %avail"
    prefix_type = custom
    low_threshold = 20
    threshold_type = percentage_avail
}
EOF
        echo ""

        if [ -n "$battery_device" ]; then
            cat <<EOF
battery main {
    device = "$battery_device"
    format = "%status %percentage %remaining"
}
EOF
        fi
    } > "$generated_config"
}

generate_config

i3status --config "$generated_config" &
child_pid=$!

trap 'if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then kill -TERM "$child_pid"; fi' INT TERM
trap 'if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then generate_config; kill -USR1 "$child_pid" 2>/dev/null || true; fi' USR1 HUP

wait "$child_pid"
