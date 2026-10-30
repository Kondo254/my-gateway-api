# my_gateway_api

Identifies the default route gateway IP address by parsing the host routing table.

## Usage

```bash
source my_gateway_api.sh

gw="$(gateway_detect)" || { echo "no default gateway found"; exit 1; }
echo "Gateway: ${gw}"
```

The library exports a single function:

- `gateway_detect` — takes no arguments, prints the default route gateway IP to stdout, returns 0 on success or 1 if no default gateway was found.

## Why this exists

Determining the default gateway from a shell script usually means grepping the output of `ip route` or `netstat -rn` and hoping the column layout matches your assumption. This library centralises that parsing with explicit handling for the two common output formats so callers don't have to re-derive it.

The trade-off: we parse human-readable command output rather than reading `/proc/net/route` directly. That file is Linux-only and encodes addresses in hex with reversed byte order — correct but error-prone. Command output is legible and available across more systems, at the cost of depending on `ip` or `netstat` being installed.

## Behaviour notes

- `ip route` is tried first; `netstat -rn` is the fallback.
- If multiple default routes exist, the **first** one reported is returned. Metric comparison is intentionally avoided because `ip route` and `netstat` represent priorities differently and combining the two semantics reliably is not possible.
- A default route with no `via` field (link-local) is not returned; the search continues to the fallback command.
- If neither command exists or neither reports a default route, `gateway_detect` returns exit code 1 and prints nothing.

## Awkward edge

On systems where the default route has no gateway (e.g. point-to-point links), there is no IP to report. The function will return 1 in that case. Do not assume a successful exit on every host with network connectivity.
