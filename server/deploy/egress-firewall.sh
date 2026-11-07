#!/usr/bin/env bash
# Linux Docker iptables backend only. Never flush global/other project rules.
set -euo pipefail

action="${1:-status}"
bridge="${RECORDPOV_BRIDGE:-br-recordpov}"
subnet="${RECORDPOV_SUBNET:-172.30.83.0/29}"
address="${RECORDPOV_ADDRESS:-172.30.83.2}"

case "$action" in apply|remove|status|render) ;; *) echo "Usage: $0 {apply|remove|status|render}" >&2; exit 2;; esac
[[ "$bridge" =~ ^br-recordpov[a-z0-9-]*$ && ${#bridge} -le 15 ]] || { echo "Refusing an unscoped bridge name" >&2; exit 2; }
python3 - "$subnet" "$address" <<'PY'
import ipaddress, sys
network = ipaddress.IPv4Network(sys.argv[1], strict=True)
address = ipaddress.IPv4Address(sys.argv[2])
private = [ipaddress.IPv4Network(x) for x in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')]
if not (24 <= network.prefixlen <= 30 and any(network.subnet_of(x) for x in private)
        and address in network and address not in (network.network_address, network.broadcast_address)):
    raise SystemExit('Refusing invalid/nonprivate scoped resolver subnet or address')
PY

rules4() {
  cat <<EOF
*filter
:RECORDPOV-EGRESS - [0:0]
:RECORDPOV-HOST - [0:0]
-F RECORDPOV-EGRESS
-F RECORDPOV-HOST
-A RECORDPOV-EGRESS -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
EOF
  for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4; do
    echo "-A RECORDPOV-EGRESS -d $cidr -j REJECT"
  done
  cat <<EOF
-A RECORDPOV-EGRESS -p tcp -m multiport --dports 53,80,443 -j RETURN
-A RECORDPOV-EGRESS -p udp --dport 53 -j RETURN
-A RECORDPOV-EGRESS -j REJECT
-A RECORDPOV-HOST -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
-A RECORDPOV-HOST -j REJECT
COMMIT
EOF
}

rules6() {
  cat <<'EOF'
*filter
:RECORDPOV6-EGRESS - [0:0]
:RECORDPOV6-HOST - [0:0]
-F RECORDPOV6-EGRESS
-F RECORDPOV6-HOST
-A RECORDPOV6-EGRESS -j REJECT
-A RECORDPOV6-HOST -j REJECT
COMMIT
EOF
}

if [[ "$action" == render ]]; then
  rules4
  echo "# IPv4 hooks: DOCKER-USER and INPUT, -i $bridge -s $address/32"
  rules6
  echo "# IPv6 hooks: FORWARD and INPUT, -i $bridge (IPv6 disabled for this dedicated network)"
  exit 0
fi

[[ "$(uname -s)" == Linux && "$EUID" == 0 ]] || { echo "Only run on the authorized Linux Docker host as root" >&2; exit 2; }
for binary in iptables iptables-restore ip6tables ip6tables-restore flock; do
  command -v "$binary" >/dev/null || { echo "Missing required Linux tool: $binary" >&2; exit 2; }
done
exec 9>/run/lock/recordpov-egress.lock
flock -x 9

forward4=(-i "$bridge" -s "$address/32" -j RECORDPOV-EGRESS)
host4=(-i "$bridge" -s "$address/32" -j RECORDPOV-HOST)
forward6=(-i "$bridge" -j RECORDPOV6-EGRESS)
host6=(-i "$bridge" -j RECORDPOV6-HOST)

if [[ "$action" == apply ]]; then
  command -v docker >/dev/null || { echo "Docker CLI is required for deployment preflight" >&2; exit 2; }
  [[ "$(docker info --format '{{.LiveRestoreEnabled}}')" == false ]] || { echo "Refusing Docker live-restore: worker must not survive a daemon/firewall restart. Use a separate compatible host; do not silently change shared Docker settings." >&2; exit 2; }
  iptables -w 10 -S DOCKER-USER >/dev/null 2>&1 || { echo "DOCKER-USER missing: requires Docker iptables backend, not native nftables backend" >&2; exit 2; }
  iptables -w 10 -C FORWARD -j DOCKER-USER 2>/dev/null || { echo "DOCKER-USER is not in the active forwarding path; refusing unguarded deployment" >&2; exit 2; }
  # Update ONLY our chains atomically before attaching them or starting a worker.
  rules4 | iptables-restore --wait 10 --noflush
  rules6 | ip6tables-restore --wait 10 --noflush
  iptables -w 10 -C DOCKER-USER "${forward4[@]}" 2>/dev/null || iptables -w 10 -I DOCKER-USER 1 "${forward4[@]}"
  iptables -w 10 -C INPUT "${host4[@]}" 2>/dev/null || iptables -w 10 -I INPUT 1 "${host4[@]}"
  ip6tables -w 10 -C FORWARD "${forward6[@]}" 2>/dev/null || ip6tables -w 10 -I FORWARD 1 "${forward6[@]}"
  ip6tables -w 10 -C INPUT "${host6[@]}" 2>/dev/null || ip6tables -w 10 -I INPUT 1 "${host6[@]}"
  echo "RecordPOV resolver egress guard applied to $bridge / $address only (IPv6 bridge disabled)."
elif [[ "$action" == remove ]]; then
  # Stop the project FIRST. Never remove the guard from a running resolver.
  for chain in DOCKER-USER INPUT; do
    if [[ "$chain" == DOCKER-USER ]]; then args=("${forward4[@]}"); else args=("${host4[@]}"); fi
    while iptables -w 10 -C "$chain" "${args[@]}" 2>/dev/null; do iptables -w 10 -D "$chain" "${args[@]}"; done
  done
  for chain in FORWARD INPUT; do
    if [[ "$chain" == FORWARD ]]; then args=("${forward6[@]}"); else args=("${host6[@]}"); fi
    while ip6tables -w 10 -C "$chain" "${args[@]}" 2>/dev/null; do ip6tables -w 10 -D "$chain" "${args[@]}"; done
  done
  for chain in RECORDPOV-EGRESS RECORDPOV-HOST; do
    if iptables -w 10 -S "$chain" >/dev/null 2>&1; then iptables -w 10 -F "$chain"; iptables -w 10 -X "$chain"; fi
  done
  for chain in RECORDPOV6-EGRESS RECORDPOV6-HOST; do
    if ip6tables -w 10 -S "$chain" >/dev/null 2>&1; then ip6tables -w 10 -F "$chain"; ip6tables -w 10 -X "$chain"; fi
  done
  echo "Only RecordPOV egress guard removed."
else
  iptables -w 10 -nvL RECORDPOV-EGRESS
  iptables -w 10 -nvL RECORDPOV-HOST
  ip6tables -w 10 -nvL RECORDPOV6-EGRESS
  ip6tables -w 10 -nvL RECORDPOV6-HOST
  iptables -w 10 -C DOCKER-USER "${forward4[@]}"
  iptables -w 10 -C INPUT "${host4[@]}"
  ip6tables -w 10 -C FORWARD "${forward6[@]}"
  ip6tables -w 10 -C INPUT "${host6[@]}"
fi
