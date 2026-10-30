#!/usr/bin/env bash
# shellcheck shell=bash
#
# my_gateway_api.sh — identify the default route gateway IP address.
#
# The library exposes a single function, gateway_detect, which parses the
# routing table of the host it runs on and prints the gateway IP used for
# the default route (destination 0.0.0.0/0). The command that produced the
# table is never echoed to the user; only the parsed IP is written to stdout.
#
# Why parse text instead of reading /proc/net/route directly?
# /proc/net/route exists only on Linux and encodes addresses in hex in
# little-endian byte order, which is easy to misread. `ip route` and
# `netstat -rn` produce human-readable, well-structured output across
# a much wider range of systems. We trade a small amount of portability
# (we depend on one of those two commands existing) for correctness and
# legibility.
#
# Interpretation choice (stated plainly):
# If multiple default routes exist, the FIRST one reported by the routing
# table command is returned. We do not try to pick a "preferred" default
# by comparing metrics — that would require knowing the metric semantics
# of each OS, which differs between `ip route` (single number) and
# `netstat` (separate Priority and Metric columns on some systems).
# First-wins is deterministic and predictable.

set -euo pipefail

# gateway_detect
#
# Prints the default route gateway IP address to stdout.
# Returns 0 on success, 1 if no default gateway could be found.
#
# The function tries `ip route` first (modern Linux) and falls back to
# `netstat -rn` (BSDs, macOS, older Linux). If neither command is available
# or neither reports a default route, the function returns 1.
gateway_detect() {
    local line

    # --- Try `ip route show` ------------------------------------------------
    # `ip route` output for a default route looks like:
    #     default via 192.168.1.1 dev eth0 proto dhcp metric 100
    # The "via" field is the gateway. We match lines whose destination is
    # exactly "default" and extract the token immediately after "via".
    if command -v ip >/dev/null 2>&1; then
        while IFS= read -r line; do
            # Strip leading whitespace so the destination token is field 1.
            local trimmed
            trimmed="${line##"${line%%[![:space:]]*}"}"
            if [[ "${trimmed}" == default\ * ]]; then
                # Break the line into words; find "via" and return the next word.
                local -a words
                read -ra words <<<"${trimmed}"
                local i
                for ((i = 0; i < ${#words[@]} - 1; i++)); do
                    if [[ "${words[i]}" == "via" ]]; then
                        printf '%s\n' "${words[i + 1]}"
                        return 0
                    fi
                done
            fi
        done < <(ip route show 2>/dev/null)
    fi

    # --- Fallback: `netstat -rn` -------------------------------------------
    # netstat output differs by platform:
    #   Linux:  Destination  Gateway       Genmask  Flags ... 0.0.0.0  192.168.1.1  0.0.0.0  UG ...
    #   BSD/macOS: Destination  Gateway  Netmask  Flags ... default  192.168.1.1  UGS ...
    # On both, column 2 is the gateway when the destination is the default route.
    # We treat a destination of "0.0.0.0" or "default" as the default route.
    if command -v netstat >/dev/null 2>&1; then
        while IFS= read -r line; do
            local trimmed
            trimmed="${line##"${line%%[![:space:]]*}"}"
            # Skip the header line and blank lines.
            case "${trimmed}" in
                "" | Destination*) continue ;;
            esac
            local -a words
            read -ra words <<<"${trimmed}"
            if [[ ${#words[@]} -ge 2 ]]; then
                if [[ "${words[0]}" == "default" || "${words[0]}" == "0.0.0.0" ]]; then
                    local gw="${words[1]}"
                    # On some systems the gateway is shown as the interface name when
                    # the route is link-local; we only return it if it looks like an IP.
                    if [[ "${gw}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                        printf '%s\n' "${gw}"
                        return 0
                    fi
                fi
            fi
        done < <(netstat -rn 2>/dev/null)
    fi

    return 1
}
