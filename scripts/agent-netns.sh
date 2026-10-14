#!/usr/bin/env bash
#
# Gives an agent user its own network namespace, so that it cannot reach the
# local services of other agents, or of the VM, over loopback or the VM
# address. setup-ai-user.sh installs this file as /usr/local/sbin/agent-netns
# and installs agent-netns@.service, which runs it at boot. Run as root.
#
#   agent-netns up <username>      Make the namespace. Safe to run again.
#   agent-netns down <username>    Remove the namespace. The subnet stays
#                                  reserved in CONF_DIR for the next up.
#   agent-netns status             List the agents and their namespaces.
#
# Each agent gets the subnet ${NET_PREFIX}.<n>.0/24. The VM side of the veth
# pair is veth-agent<n> at .1, and the agent side is eth0 at .2. The number
# n is kept in CONF_DIR/<username>. ${NET_PREFIX}.0.1 on lo is the DNS
# address for every agent: systemd-resolved listens there.
#
# The nftables rules in /etc/nftables.d/80-agentfilter.nft match the
# veth-agent* interfaces. They drop traffic between agents, drop traffic
# from an agent to the VM except DNS, block the cloud metadata endpoint,
# and masquerade the rest.
#
set -euo pipefail

NET_PREFIX="10.200"
CONF_DIR="/etc/slopbot/netns"
# setup-ai-user.sh writes the prefix it used here.
# shellcheck source=/dev/null
[[ -f /etc/default/agent-netns ]] && source /etc/default/agent-netns
DNS_IP="${NET_PREFIX}.0.1"

usage() {
    echo "Usage: $(basename "$0") up <username> | down <username> | status" >&2
    exit 2
}

ns_name() {
    echo "agent-$1"
}

# The lowest number from 1 to 254 that no agent has.
alloc_index() {
    local n
    for n in $(seq 1 254); do
        if ! grep -qsx "$n" "$CONF_DIR"/* 2>/dev/null; then
            echo "$n"
            return 0
        fi
    done
    echo "ERROR: no free subnet under ${NET_PREFIX}.0.0/16" >&2
    return 1
}

cmd_up() {
    local user="$1" ns n host_if host_ip ns_ip
    ns="$(ns_name "$user")"
    if ! id "$user" &>/dev/null; then
        echo "ERROR: user '${user}' does not exist" >&2
        exit 1
    fi

    mkdir -p "$CONF_DIR"
    if [[ -f "${CONF_DIR}/${user}" ]]; then
        n="$(<"${CONF_DIR}/${user}")"
    else
        n="$(alloc_index)"
        echo "$n" > "${CONF_DIR}/${user}"
    fi
    host_if="veth-agent${n}"
    host_ip="${NET_PREFIX}.${n}.1"
    ns_ip="${NET_PREFIX}.${n}.2"

    [[ -e "/run/netns/${ns}" ]] || ip netns add "$ns"
    # Deleting a namespace deletes its interfaces, and the VM side of a veth
    # pair goes with its peer, so the pair is either whole or absent.
    ip link show "$host_if" &>/dev/null \
        || ip link add "$host_if" type veth peer name eth0 netns "$ns"
    ip addr replace "${host_ip}/24" dev "$host_if"
    ip link set "$host_if" up
    ip addr replace "${DNS_IP}/32" dev lo
    ip -n "$ns" addr replace "${ns_ip}/24" dev eth0
    ip -n "$ns" link set lo up
    ip -n "$ns" link set eth0 up
    ip -n "$ns" route replace default via "$host_ip"

    # ip netns exec mounts this file over /etc/resolv.conf in the namespace.
    # The stub resolver of systemd-resolved is at 127.0.0.53 in the VM
    # namespace, which the agent cannot reach, so setup-ai-user.sh makes
    # resolved listen on DNS_IP as well. The drop-in it writes is the sign
    # of that, and unlike the state of the service it is stable at boot.
    # Without it, the agent uses the servers of the VM, minus any loopback
    # stub, which it could not reach.
    mkdir -p "/etc/netns/${ns}"
    if [[ -f /etc/systemd/resolved.conf.d/agent-netns.conf ]]; then
        echo "nameserver ${DNS_IP}" > "/etc/netns/${ns}/resolv.conf"
    else
        grep -E '^(nameserver|search|options)' /etc/resolv.conf \
            | grep -vE '^nameserver 127\.' \
            > "/etc/netns/${ns}/resolv.conf" || true
    fi
    echo "${ns}: ${host_if} ${host_ip} <-> eth0 ${ns_ip}"
}

cmd_down() {
    local user="$1" ns
    ns="$(ns_name "$user")"
    if [[ -e "/run/netns/${ns}" ]]; then
        ip netns delete "$ns"
        echo "${ns}: removed"
    else
        echo "${ns}: not present"
    fi
    rm -rf "/etc/netns/${ns}"
}

cmd_status() {
    local f user n ns state
    shopt -s nullglob
    for f in "$CONF_DIR"/*; do
        user="$(basename "$f")"
        n="$(<"$f")"
        ns="$(ns_name "$user")"
        if [[ -e "/run/netns/${ns}" ]]; then state="up"; else state="down"; fi
        printf '%-20s %-5s %s.%s.2  veth-agent%s\n' "$user" "$state" "$NET_PREFIX" "$n" "$n"
    done
}

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: run this as root" >&2
    exit 1
fi

case "${1:-}" in
    up|down)
        [[ -n "${2:-}" ]] || usage
        "cmd_$1" "$2"
        ;;
    status)
        cmd_status
        ;;
    *)
        usage
        ;;
esac
