#!/bin/sh

PROG_NAME="${0##*/}"

usage() {
	cat <<EOF
Usage: $PROG_NAME {start|stop|reload|help}

  start   Generate and apply nftables isolation rules
  stop    Remove all isolation rules
  reload  Re-generate and re-apply isolation rules
  help    Show this help message

The isolation tier is selected by the 'mode' option in /etc/config/ap-isolation:

  filter   Filter inter-client ARP, broadcast and multicast. Makes no gateway
           assumption; aims to be paired with bridge/AP isolation
           (isolate=1/bridge_isolate=1). This is the default.

  gateway  Default-drop gateway allowlist: wireless clients may only exchange
           traffic with the main router (gateway_ip/gateway_mac); every other
           broadcast, multicast and unicast frame is dropped. Requires both
           gateway_ip and gateway_mac and assumes a single main router that also
           serves DHCP/DNS.
EOF
}

_is_enabled() {
	local val
	config_get_bool val settings enabled 0
	[ "$val" = "1" ]
}

_get_ifname() {
	local section="$1"
	local ifname

	config_get ifname "$section" ifname
	[ -n "$ifname" ] && [ -d "/sys/class/net/$ifname" ] && {
		echo "$ifname"
		return 0
	}

	ifname="${section#wifi_}"
	ifname="${ifname//_/-}"
	[ -d "/sys/class/net/$ifname" ] && {
		echo "$ifname"
		return 0
	}

	ifname="${section//_/-}"
	[ -d "/sys/class/net/$ifname" ] && {
		echo "$ifname"
		return 0
	}

	return 1
}

_find_isolated() {
	local section="$1"
	local isolated
	local ifname

	config_get isolated "$section" isolate
	[ "$isolated" != "1" ] && return

	ifname="$(_get_ifname "$section")"
	[ -z "$ifname" ] && {
		logger -t ap-isolation "Warning: interface for section '$section' not found, skipping"
		return
	}

	[ -n "$IFACES" ] && IFACES="$IFACES, "
	IFACES="${IFACES}\"$ifname\""
}

collect_ifaces() {
	IFACES=""
	config_foreach _find_isolated wifi-iface
}

_remove_rules() {
	nft delete table bridge ap_isolation 2>/dev/null
}

# Tier 1: blacklist ARP/broadcast/multicast between clients. No gateway
# allowlist, so unicast between clients on a shared wire is not prevented
# (bridge port isolation is expected to cover the same-AP case).
_emit_filter() {
	local ifaces="$1"
	local vlan="$2"
	local gw_ip="$3"
	local ipv6_enabled="$4"
	local gw_mac="$5"

	cat <<EOF
table bridge ap_isolation {
	set wlan {
		type ifname
		elements = { ${ifaces} }
	}

	chain forward {
		type filter hook forward priority filter; policy accept;

EOF

	if [ -n "$gw_ip" ] && [ -n "$gw_mac" ]; then
		cat <<EOF
		iifname @wlan ${vlan} arp operation request arp daddr ip ${gw_ip} counter accept
		iifname @wlan ether daddr ${gw_mac} ${vlan} arp operation reply counter accept
		iifname @wlan ${vlan} ether type arp counter drop
		iifname @wlan ${vlan} ether type vlan vlan type arp counter drop

		oifname @wlan ether saddr ${gw_mac} arp operation reply counter accept
		oifname @wlan ether saddr ${gw_mac} arp operation request counter accept
		oifname @wlan ether type arp counter drop
		oifname @wlan ether type vlan vlan type arp counter drop
EOF
	elif [ -n "$gw_ip" ]; then
		cat <<EOF
		iifname @wlan ${vlan} arp operation request arp daddr ip ${gw_ip} counter accept
		iifname @wlan ${vlan} arp operation reply counter accept
		iifname @wlan ${vlan} ether type arp counter drop
		iifname @wlan ${vlan} ether type vlan vlan type arp counter drop
EOF
	fi

	cat <<EOF
		iifname @wlan ${vlan} ip protocol udp udp sport 68 udp dport 67 counter accept
		oifname @wlan ip protocol udp udp sport 67 udp dport 68 counter accept
EOF

	if [ "$ipv6_enabled" = "1" ]; then
		cat <<EOF
		iifname @wlan ${vlan} ip6 nexthdr icmpv6 icmpv6 type nd-router-solicit counter accept
		oifname @wlan ip6 nexthdr icmpv6 icmpv6 type nd-router-advert counter accept
		oifname @wlan ip6 nexthdr icmpv6 icmpv6 type nd-redirect counter accept
		iifname @wlan ${vlan} ip6 nexthdr icmpv6 icmpv6 type nd-neighbor-solicit counter accept
		oifname @wlan ip6 nexthdr icmpv6 icmpv6 type nd-neighbor-solicit counter accept
		iifname @wlan ${vlan} ip6 nexthdr icmpv6 icmpv6 type nd-neighbor-advert counter accept
		oifname @wlan ip6 nexthdr icmpv6 icmpv6 type nd-neighbor-advert counter accept
		iifname @wlan ${vlan} ip6 nexthdr udp udp sport 546 udp dport 547 counter accept
		oifname @wlan ip6 nexthdr udp udp sport 547 udp dport 546 counter accept
EOF
	fi

	cat <<EOF
		iifname @wlan ${vlan} ether daddr ff:ff:ff:ff:ff:ff counter drop
		iifname @wlan ${vlan} ether daddr & 01:00:00:00:00:00 == 01:00:00:00:00:00 counter drop
		oifname @wlan ether daddr ff:ff:ff:ff:ff:ff counter drop
		oifname @wlan ether daddr & 01:00:00:00:00:00 == 01:00:00:00:00:00 counter drop
	}
}
EOF
}

# Tier 2 (gateway): default-drop gateway allowlist. Every frame touching a
# wireless port must involve the main router, except for the DHCP/ARP/IPv6
# control plane needed to reach it. Non-wireless bridging (e.g. any wired
# VLAN) is left untouched.
_emit_gateway() {
	local ifaces="$1"
	local vlan="$2"
	local gw_ip="$3"
	local gw_mac="$4"
	local ipv6_enabled="$5"

	cat <<EOF
table bridge ap_isolation {
	set wlan {
		type ifname
		elements = { ${ifaces} }
	}

	chain forward {
		type filter hook forward priority filter; policy drop;

		# Leave traffic that does not touch a wireless port alone.
		iifname != @wlan oifname != @wlan counter accept

		# DHCP: clients may ask on the segment; only the main router may answer.
		iifname @wlan ${vlan} ip protocol udp udp sport 68 udp dport 67 counter accept
		oifname @wlan ether saddr ${gw_mac} ip protocol udp udp sport 67 udp dport 68 counter accept

		# ARP: resolve only the gateway address; reply only to the gateway;
		# accept anything the gateway originates.
		iifname @wlan ${vlan} arp operation request arp daddr ip ${gw_ip} counter accept
		iifname @wlan ether daddr ${gw_mac} ${vlan} arp operation reply counter accept
		oifname @wlan ether saddr ${gw_mac} counter accept

		# Internet: everything to the main router, nothing else.
		iifname @wlan ether daddr ${gw_mac} ${vlan} counter accept
EOF

	if [ "$ipv6_enabled" = "1" ]; then
		cat <<EOF

		# IPv6 control plane. Gateway-originated RA/NA/redirect is already
		# covered by the gateway source rule above.
		iifname @wlan ${vlan} ip6 nexthdr icmpv6 icmpv6 type nd-router-solicit counter accept
		iifname @wlan ${vlan} ip6 nexthdr icmpv6 icmpv6 type nd-neighbor-solicit counter accept
		iifname @wlan ${vlan} ip6 nexthdr udp udp sport 546 udp dport 547 counter accept
EOF
	fi

	cat <<EOF

		# Anything else touching a wireless port (client<->client,
		# client<->wire, foreign broadcast/multicast) is dropped.
		counter drop
	}
}
EOF
}

_generate_rules() {
	local mode="$1"
	local ifaces="$2"
	local vlan_id="$3"
	local gw_ip="$4"
	local ipv6_enabled="$5"
	local gw_mac="$6"
	local vlan

	[ -z "$ifaces" ] && return 1

	# VLAN matching is only reliable on the ingress (STA -> bridge) path:
	# the bridge has already consumed the 802.1Q tag before the egress
	# forward hook, so egress rules must not be VLAN-qualified.
	vlan=""
	[ -n "$vlan_id" ] && [ "$vlan_id" != "0" ] && vlan="vlan id ${vlan_id}"

	case "$mode" in
		gateway)
			if [ -z "$gw_ip" ] || [ -z "$gw_mac" ]; then
				logger -t ap-isolation "Error: mode 'gateway' requires gateway_ip and gateway_mac; keeping current rules"
				return 2
			fi
			_emit_gateway "$ifaces" "$vlan" "$gw_ip" "$gw_mac" "$ipv6_enabled"
			;;
		*)
			_emit_filter "$ifaces" "$vlan" "$gw_ip" "$ipv6_enabled" "$gw_mac"
			;;
	esac
}

_apply() {
	local tmp swap err
	local rc

	tmp="$(mktemp /tmp/ap-isolation.XXXXXX)" || return 1
	swap="$(mktemp /tmp/ap-isolation.XXXXXX)" || {
		rm -f "$tmp"
		return 1
	}

	_generate_rules "$@" > "$tmp" || {
		rc=$?
		rm -f "$tmp" "$swap"
		return "$rc"
	}

	# Single transaction: 'add table' is idempotent and, unlike a bare table
	# declaration, is visible to the following delete inside the same batch,
	# so this replaces the live table atomically.
	{
		echo "add table bridge ap_isolation"
		echo "delete table bridge ap_isolation"
		cat "$tmp"
	} > "$swap"

	# Validate the exact transaction before touching the live table.
	if ! err="$(nft -c -f "$swap" 2>&1)"; then
		logger -t ap-isolation "Error: generated ruleset failed validation: $err"
		rm -f "$tmp" "$swap"
		return 1
	fi

	if ! err="$(nft -f "$swap" 2>&1)"; then
		rc=$?
		logger -t ap-isolation "Error: nft -f failed with status $rc: $err"
		rm -f "$tmp" "$swap"
		return "$rc"
	fi

	rm -f "$tmp" "$swap"
}

do_start() {
	[ "$(command -v nft)" ] || {
		logger -t ap-isolation "nftables not available, skipping"
		return 1
	}

	. /lib/functions.sh

	config_load ap-isolation
	_is_enabled || {
		_remove_rules
		logger -t ap-isolation "disabled by config, rules removed"
		return 0
	}

	local mode vlan_id gw_ip gw_mac ipv6_enabled
	config_get mode settings mode filter
	config_get vlan_id settings vlan_id
	config_get gw_ip settings gateway_ip
	config_get gw_mac settings gateway_mac
	config_get_bool ipv6_enabled settings ipv6_enabled 0

	config_load wireless
	collect_ifaces
	[ -z "$IFACES" ] && {
		_remove_rules
		logger -t ap-isolation "no isolated interfaces found, rules removed"
		return 0
	}

	_apply "$mode" "$IFACES" "$vlan_id" "$gw_ip" "$ipv6_enabled" "$gw_mac" || {
		logger -t ap-isolation "Error: failed to apply rules"
		return 1
	}

	logger -t ap-isolation "rules applied (mode=$mode) for interfaces: ${IFACES}"
}

do_stop() {
	_remove_rules
	logger -t ap-isolation "rules removed"
}

do_reload() {
	do_start
}

case "${1:-help}" in
	start) do_start ;;
	stop) do_stop ;;
	reload) do_reload ;;
	help|--help|-h) usage ;;
	*)
		echo "Unknown command: $1"
		usage
		exit 1
		;;
esac
