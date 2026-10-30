#!/usr/bin/env bash
# shellcheck shell=bash
#
# Test suite for my_gateway_api.sh.
#
# These tests exercise gateway_detect indirectly by manipulating PATH so
# that fake `ip` and `netstat` binaries (created as temporary scripts) are
# found instead of the real system commands. This keeps the tests fully
# deterministic and independent of the host's actual routing table.
#
# Run: bash test_my_gateway_api.sh

set -euo pipefail

# --- Test harness -----------------------------------------------------------

PASS=0
FAIL=0

# assert_eq "label" "expected" "actual"
# Prints TAP-like output and increments PASS or FAIL.
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        printf 'ok - %s\n' "${label}"
        PASS=$((PASS + 1))
    else
        printf 'not ok - %s\n' "${label}"
        printf '  expected: %q\n' "${expected}"
        printf '  actual:   %q\n' "${actual}"
        FAIL=$((FAIL + 1))
    fi
}

# assert_return "label" "expected_code" "actual_code"
assert_return() {
    local label="$1" expected="$2" actual="$3"
    assert_eq "${label} (exit code)" "${expected}" "${actual}"
}

# --- Setup ------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=my_gateway_api.sh
source "${SCRIPT_DIR}/my_gateway_api.sh"

# Create a temporary directory for fake commands and make it the first entry
# in PATH. We do not overwrite PATH entirely so that coreutils (printf, etc.)
# remain available.
FAKE_BIN="$(mktemp -d)"
trap 'rm -rf "${FAKE_BIN}"' EXIT
export PATH="${FAKE_BIN}:${PATH}"

# make_fake_command "name" "script contents"
make_fake_command() {
    local name="$1" script="$2"
    local path="${FAKE_BIN}/${name}"
    printf '#!/usr/bin/env bash\n%s\n' "${script}" >"${path}"
    chmod +x "${path}"
}

# --- Tests ------------------------------------------------------------------

test_ip_route_standard_default() {
    make_fake_command "ip" 'cat <<EOF
192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.42
default via 192.168.1.1 dev eth0 proto dhcp metric 100
10.0.0.0/8 via 10.0.0.254 dev eth1 metric 200
EOF'
    make_fake_command "netstat" 'echo "should not be called" >&2; exit 1'

    local got rc
    got="$(gateway_detect)" && rc=0 || rc=$?
    assert_eq "ip route: standard default gateway" "192.168.1.1" "${got}"
    assert_return "ip route: exit code" "0" "${rc}"
}

test_ip_route_no_default() {
    make_fake_command "ip" 'cat <<EOF
192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.42
10.0.0.0/8 via 10.0.0.254 dev eth1 metric 200
EOF'
    make_fake_command "netstat" 'exit 1'

    local got rc
    got="$(gateway_detect 2>/dev/null)" && rc=0 || rc=$?
    assert_eq "ip route: no default route returns empty" "" "${got}"
    assert_return "ip route: no default route exit code" "1" "${rc}"
}

test_ip_route_default_without_via() {
    # A default route with no gateway (link-local) should not produce a result
    # from `ip route`; we fall through to netstat (also faked to return nothing).
    make_fake_command "ip" 'cat <<EOF
default dev eth0 proto kernel scope link src 192.168.1.42
EOF'
    make_fake_command "netstat" 'exit 1'

    local got rc
    got="$(gateway_detect 2>/dev/null)" && rc=0 || rc=$?
    assert_eq "ip route: default without via returns empty" "" "${got}"
    assert_return "ip route: default without via exit code" "1" "${rc}"
}

test_ip_route_multiple_defaults_first_wins() {
    make_fake_command "ip" 'cat <<EOF
default via 10.0.0.1 dev eth0 metric 100
default via 10.0.0.2 dev eth1 metric 50
EOF'
    make_fake_command "netstat" 'exit 1'

    local got rc
    got="$(gateway_detect)" && rc=0 || rc=$?
    assert_eq "ip route: first default wins" "10.0.0.1" "${got}"
    assert_return "ip route: first default exit code" "0" "${rc}"
}

test_netstat_linux_format() {
    # When `ip` is absent, we fall back to netstat. This mimics Linux netstat -rn.
    make_fake_command "ip" 'exit 127'
    make_fake_command "netstat" 'cat <<EOF
Kernel IP routing table
Destination     Gateway         Genmask         Flags   MSS Window  irtt Iface
0.0.0.0         192.168.1.1     0.0.0.0         UG        0 0          0 eth0
192.168.1.0     0.0.0.0         255.255.255.0   U         0 0          0 eth0
EOF'

    local got rc
    got="$(gateway_detect)" && rc=0 || rc=$?
    assert_eq "netstat: Linux format gateway" "192.168.1.1" "${got}"
    assert_return "netstat: Linux format exit code" "0" "${rc}"
}

test_netstat_bsd_format() {
    # BSD/macOS netstat -rn uses "default" as the destination and puts the
    # gateway in column 2.
    make_fake_command "ip" 'exit 127'
    make_fake_command "netstat" 'cat <<EOF
Routing tables

Internet:
Destination        Gateway            Flags      Netif Expire
default            10.0.0.1           UGSc         en0
10.0.0.0/24        link#1             UCS          en0
EOF'

    local got rc
    got="$(gateway_detect)" && rc=0 || rc=$?
    assert_eq "netstat: BSD format gateway" "10.0.0.1" "${got}"
    assert_return "netstat: BSD format exit code" "0" "${rc}"
}

test_netstat_no_default() {
    make_fake_command "ip" 'exit 127'
    make_fake_command "netstat" 'cat <<EOF
Kernel IP routing table
Destination     Gateway         Genmask         Flags   MSS Window  irtt Iface
192.168.1.0     0.0.0.0         255.255.255.0   U         0 0          0 eth0
EOF'

    local got rc
    got="$(gateway_detect 2>/dev/null)" && rc=0 || rc=$?
    assert_eq "netstat: no default returns empty" "" "${got}"
    assert_return "netstat: no default exit code" "1" "${rc}"
}

test_neither_command_available() {
    # Simulate a system without ip or netstat by making both exit 127.
    make_fake_command "ip" 'exit 127'
    make_fake_command "netstat" 'exit 127'

    local got rc
    got="$(gateway_detect 2>/dev/null)" && rc=0 || rc=$?
    assert_eq "neither command: returns empty" "" "${got}"
    assert_return "neither command: exit code" "1" "${rc}"
}

test_ip_route_skips_non_default_via() {
    # Ensure we don't accidentally grab a "via" from a non-default route.
    make_fake_command "ip" 'cat <<EOF
default via 172.16.0.1 dev eth0 proto dhcp metric 100
10.8.0.0/24 via 10.8.0.1 dev tun0 metric 50
EOF'
    make_fake_command "netstat" 'exit 1'

    local got rc
    got="$(gateway_detect)" && rc=0 || rc=$?
    assert_eq "ip route: skips non-default via" "172.16.0.1" "${got}"
    assert_return "ip route: skips non-default via exit code" "0" "${rc}"
}

# --- Run --------------------------------------------------------------------

test_ip_route_standard_default
test_ip_route_no_default
test_ip_route_default_without_via
test_ip_route_multiple_defaults_first_wins
test_netstat_linux_format
test_netstat_bsd_format
test_netstat_no_default
test_neither_command_available
test_ip_route_skips_non_default_via

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
