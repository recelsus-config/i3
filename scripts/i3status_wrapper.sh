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
    local node=""
    local -a battery_nodes=()

    for node in /sys/class/power_supply/*; do
        [ -d "$node" ] || continue
        local type_file="$node/type"
        [ -f "$type_file" ] || continue
        local cell_type=""
        if ! cell_type=$(cat "$type_file"); then
            continue
        fi
        case "$cell_type" in
            Battery|battery)
                battery_nodes+=("$node")
                ;;
        esac
    done

    if [ "${#battery_nodes[@]}" -gt 0 ]; then
        printf "%s" "${battery_nodes[0]}"
        return 0
    fi

    # Late fallbacks suit units like the GPD Pocket fuel gauge
    local known_paths=(
        "/sys/class/power_supply/max170xx_battery"
        "/sys/class/power_supply/bq27500-battery"
        "/sys/class/power_supply/bq24190-battery"
        "/sys/class/power_supply/BAT0"
        "/sys/class/power_supply/BAT1"
    )

    local known=""
    for known in "${known_paths[@]}"; do
        if [ -d "$known" ]; then
            printf "%s" "$known"
            return 0
        fi
    done

    return 1
}

find_temperature_path() {
    local zone=""
    local -a thermal_candidates=()

    for zone in /sys/class/thermal/thermal_zone*; do
        [ -d "$zone" ] || continue
        local type_file="$zone/type"
        local temp_file="$zone/temp"
        if [ ! -f "$type_file" ] || [ ! -f "$temp_file" ]; then
            continue
        fi
        local zone_type=""
        if ! zone_type=$(cat "$type_file"); then
            continue
        fi
        case "$zone_type" in
            x86_pkg_temp|cpu_thermal|soc_thermal|acpitz|k10temp|pch_cannonlake|soc_dts0|soc_dts1|soc_dts2|soc_dts3)
                local reading=""
                if reading=$(cat "$temp_file"); then
                    if [ -n "$reading" ] && [ "$reading" != "0" ]; then
                        thermal_candidates+=("$temp_file")
                    fi
                fi
                ;;
        esac
    done

    if [ "${#thermal_candidates[@]}" -gt 0 ]; then
        printf "%s" "${thermal_candidates[0]}"
        return 0
    fi

    local hwmon=""
    for hwmon in /sys/class/hwmon/hwmon*; do
        [ -d "$hwmon" ] || continue
        local name_file="$hwmon/name"
        [ -f "$name_file" ] || continue
        local hwmon_name=""
        if ! hwmon_name=$(cat "$name_file"); then
            continue
        fi
        case "$hwmon_name" in
            coretemp|k10temp|zenpower|cpu_thermal|soc_thermal|soc_dts0|soc_dts1|soc_dts2|soc_dts3)
                local input=""
                for input in "$hwmon"/temp*_input; do
                    [ -f "$input" ] || continue
                    local value=""
                    if value=$(cat "$input"); then
                        if [ -n "$value" ] && [ "$value" != "0" ]; then
                            printf "%s" "$input"
                            return 0
                        fi
                    fi
                done
                ;;
            *)
                local input=""
                for input in "$hwmon"/temp*_input; do
                    [ -f "$input" ] || continue
                    local label_file="${input%_input}_label"
                    if [ -f "$label_file" ]; then
                        local label=""
                        if ! label=$(cat "$label_file"); then
                            continue
                        fi
                        case "$label" in
                            *CPU*|*Tctl*|*Package*|*SoC*)
                                local value=""
                                if value=$(cat "$input"); then
                                    if [ -n "$value" ] && [ "$value" != "0" ]; then
                                        printf "%s" "$input"
                                        return 0
                                    fi
                                fi
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
    # Permit override for battery location
    local battery_path="${STATUS_BATTERY_PATH:-}"
    if [ -z "$battery_path" ]; then
        if battery_path=$(find_battery_device); then
            :
        else
            battery_path=""
        fi
    fi

    local battery_file=""
    if [ -n "$battery_path" ]; then
        if [ -d "$battery_path" ]; then
            if [ -f "$battery_path/uevent" ]; then
                battery_file="$battery_path/uevent"
            else
                battery_file="$battery_path"
            fi
        else
            battery_file="$battery_path"
        fi
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
        if [ -n "$battery_file" ]; then
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

        if [ -n "$battery_file" ]; then
            cat <<EOF
battery main {
    path = "$battery_file"
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
