# ap-isolation — Public Wi-Fi AP Client Isolation for OpenWrt (nftables)

Automatically applies bridge-level client isolation rules to wireless interfaces
that have `isolate` enabled in `/etc/config/wireless`. Uses nftables to block
ARP, broadcast, and multicast traffic between clients while allowing DHCP and
gateway ARP.

## Features

- Reads `/etc/config/wireless` — any `wifi-iface` section with `isolate='1'` is
  dynamically added to the nftables set
- All 8 original bridge-level rules: ARP filtering, DHCP passthrough,
  broadcast/multicast drop
- Bidirectional filtering blocks unwanted traffic both from and to isolated
  STAs (ingress + egress)
- Optional IPv6 support: SLAAC (ND), DHCPv6, ICMPv6 redirect passthrough
- Optional VLAN ID and gateway IP via dedicated UCI config
- Three ARP filtering tiers: none, basic, strict (with `gateway_mac`)
- Procd init script with automatic reload on wireless UCI changes
- Hotplug trigger — rules re-apply when wireless interfaces come up
- Sysupgrade-safe (files can be added to `/etc/sysupgrade.conf`)
- Minimal flash writes on deploy — md5 comparison before scp

## How It Works

```
/etc/config/wireless (isolate='1')       /etc/config/ap-isolation (vlan_id, gateway_ip)
          |                                        |
          v                                        v
          +----- /usr/sbin/ap-isolation.sh --------+
                        |
                        v
            Generates nftables ruleset
                        |
                        v
             nft -f → kernel rules
```

On boot, after wireless interfaces are up, the init script scans UCI for
interfaces with `isolate='1'`, generates an nftables ruleset with those
interfaces in a named set, and applies it. The rules reload automatically when
wireless config changes or when a wireless interface comes up.

## Project Structure

```
ap-isolation/
├── Makefile                     # OpenWrt buildroot package
├── rules.nft                    # Original reference ruleset
├── deploy.sh                    # Quick deployment to running router
└── files/
    ├── etc/
    │   ├── config/ap-isolation          # UCI config for VLAN ID / gateway IP
    │   ├── init.d/ap-isolation          # Procd init script
    │   └── hotplug.d/iface/50-ap-isolation  # Interface hotplug trigger
    └── usr/sbin/ap-isolation.sh         # Main logic script
```

## Dependencies

- `nftables` (provides `nft` binary and kernel nft support)
- `libuci` (built into all OpenWrt systems)

## Installation

### Via OpenWrt buildroot

Place in your feed or `package/` directory, then:

```
make package/ap-isolation/compile V=s
make package/ap-isolation/install
```

### Via deploy script

Copy `deploy.sh` to any Linux machine with SSH access to the router:

```
./deploy.sh -H 192.168.1.1 -P 22 -r
```

The script compares md5sums of local vs remote files before copying, avoiding
unnecessary flash writes. Run with `-h` for options. Requires `bash`, `scp`,
`ssh`, and `md5sum` on the local machine.

## Configuration

Global options in `/etc/config/ap-isolation`:

| Option | Type | Default | Description |
|---|---|---|---|
| `enabled` | boolean | `1` | Master toggle |
| `vlan_id` | integer | (empty) | 802.1Q VLAN ID for rules (empty = no VLAN match) |
| `gateway_ip` | IP address | (empty) | Gateway IPv4 for ARP allow rules (empty = no ARP filtering) |
| `gateway_mac` | MAC address | (empty) | Gateway MAC for strict bidirectional ARP filtering |
| `ipv6_enabled` | boolean | `0` | Enable IPv6 SLAAC, DHCPv6, and ND passthrough |

### Examples

```
uci set ap-isolation.settings.gateway_ip='10.65.102.1'
uci set ap-isolation.settings.vlan_id='1641'
uci commit ap-isolation
/etc/init.d/ap-isolation start
```

Enable IPv6 support (SLAAC + DHCPv6):

```
uci set ap-isolation.settings.ipv6_enabled='1'
uci commit ap-isolation
/etc/init.d/ap-isolation reload
```

Full isolation with strict ARP filtering (recommended when the gateway is
a separate device on the same L2 bridge):

```
uci set ap-isolation.settings.gateway_ip='10.65.102.1'
uci set ap-isolation.settings.gateway_mac='aa:bb:cc:dd:ee:ff'
uci set ap-isolation.settings.ipv6_enabled='1'
uci set ap-isolation.settings.vlan_id='1641'
uci commit ap-isolation
/etc/init.d/ap-isolation reload
```

### ARP Filtering Tiers

ARP rules are generated based on which options are configured:

| Tier | Config | Ingress (STA→network) | Egress (network→STA) |
|---|---|---|---|
| **None** | `gateway_ip` empty | No ARP filtering | No ARP filtering |
| **Basic** | `gateway_ip` set | Only gateway ARP requests + all ARP replies accepted from STAs. Client-to-client ARP blocked. | No ARP filtering |
| **Strict** | `gateway_ip` + `gateway_mac` set | Only gateway ARP requests + ARP replies directed to gateway MAC accepted from STAs. All other STA-generated ARP blocked. | Only ARP replies and requests from gateway MAC accepted. Spoofed/external ARP to STAs blocked. |

Broadcast and multicast traffic is blocked in both directions regardless
of the ARP tier (always generated).

## Interface Discovery

The script resolves UCI section names to kernel interface names:

1. Explicit `ifname` option in the section (highest priority)
2. Strip `wifi_` prefix, replace remaining underscores with hyphens:
   `wifi_phy1_paw` → `phy1-paw`
3. Fallback: replace underscores with hyphens directly
4. Verifies the interface exists in `/sys/class/net/` before including it

## Nftables Rules Explained

The rules operate in the **`bridge`** table family, hooking into the bridge
forward path at filter priority. The chain **policy is `accept`**: traffic
that does not match any rule passes through. Named set **`@wlan`** holds all
isolated interface names and is referenced by every rule.

### ARP rules (1–8) — conditional on `gateway_ip` / `gateway_mac`

ARP rules vary based on the configured tier:

#### Rules 1–4: Ingress ARP (STA → network)

**Strict tier** (`gateway_ip` + `gateway_mac` both set):

```
iifname @wlan vlan id 1641 arp operation request arp daddr ip 10.65.102.1 counter accept
iifname @wlan vlan id 1641 arp operation reply ether daddr aa:bb:cc:dd:ee:ff counter accept
iifname @wlan vlan id 1641 ether type arp counter drop
iifname @wlan vlan id 1641 ether type vlan vlan type arp counter drop
```

- Rule 1: STA asking "who has the gateway IP?" — required for routing
- Rule 2: STA replying ONLY to the gateway (unicast to `gateway_mac`).
  This blocks gratuitous ARP from STAs and STA-to-STA ARP replies.
- Rules 3–4: Drop all remaining ARP from STAs (client-to-client ARP, probes, etc.)

**Basic tier** (`gateway_ip` set, `gateway_mac` empty):

```
iifname @wlan vlan id 1641 arp operation request arp daddr ip 10.65.102.1 counter accept
iifname @wlan vlan id 1641 arp operation reply counter accept
iifname @wlan vlan id 1641 ether type arp counter drop
iifname @wlan vlan id 1641 ether type vlan vlan type arp counter drop
```

Same as strict but rule 2 accepts ALL ARP replies from STAs (less restrictive
— a STA could reply to another STA's ARP request). This is the original
behavior before `gateway_mac` was added.

**None** (no `gateway_ip`): all 4 rules are omitted.

#### Rules 5–8: Egress ARP (network → STA) — strict tier only

```
oifname @wlan vlan id 1641 arp operation reply ether saddr aa:bb:cc:dd:ee:ff counter accept
oifname @wlan vlan id 1641 arp operation request ether saddr aa:bb:cc:dd:ee:ff counter accept
oifname @wlan vlan id 1641 ether type arp counter drop
oifname @wlan vlan id 1641 ether type vlan vlan type arp counter drop
```

- Rule 5: Only ARP replies from the gateway reach STAs — blocks spoofed
  ARP replies from other devices on the L2 segment.
- Rule 6: Only the gateway can ARP a STA (e.g., returning internet traffic
  when the gateway needs to resolve a STA's MAC address). Other APs or
  devices probing STAs are blocked.
- Rules 7–8: Drop all remaining ARP directed at STAs (requests and replies
  from unrecognized source MACs).

These egress rules are only generated in strict tier. In basic/none tiers,
egress ARP is not filtered (allows broader compatibility but lacks
egress-side isolation).

### Rule 9 — Allow DHCP requests (client → server)

```
iifname @wlan vlan id 1641 ip protocol udp udp sport 68 udp dport 67 counter accept
```

DHCP clients use source port 68 and destination port 67 when sending
discover/request messages. This rule allows these messages from wireless
clients to the DHCP server so they can obtain an IP address.

### Rule 10 — Allow DHCP replies (server → client)

```
oifname @wlan vlan id 1641 ip protocol udp udp sport 67 udp dport 68 counter accept
```

DHCP servers respond from port 67 to port 68. The `oifname` keyword matches
the bridge egress port — this allows DHCP offers/acks to reach wireless
clients.

### Rule 11 — Drop Ethernet broadcast frames (ingress)

```
iifname @wlan vlan id 1641 ether daddr ff:ff:ff:ff:ff:ff counter drop
```

Blocks all Ethernet broadcast frames (destination `ff:ff:ff:ff:ff:ff`). ARP
and DHCP broadcasts are already handled by rules 1–10. This stops any other
broadcast protocols (NetBIOS, mDNS, LLMNR, etc.) from leaking between clients.

### Rule 12 — Drop Ethernet multicast frames (ingress)

```
iifname @wlan vlan id 1641 ether daddr & 01:00:00:00:00:00 == 01:00:00:00:00:00 counter drop
```

Matches any destination MAC where the first byte's least significant bit is 1
(the multicast/broadcast flag). This catches all multicast traffic (mDNS, UPnP,
IGMP, etc.) **originating from** wireless STAs, except for IPv6 ND and DHCPv6
which are accepted by the IPv6 rules when `ipv6_enabled` is set.

### Rule 13 — Drop Ethernet broadcast frames (egress)

```
oifname @wlan vlan id 1641 ether daddr ff:ff:ff:ff:ff:ff counter drop
```

Blocks broadcast frames arriving from other bridge ports (e.g., other APs on
the same L2 segment) from reaching wireless STAs. DHCPv4 replies and IPv6
traffic are already accepted by rules 10 and 15–23 before this drop. ARP
is handled separately by the egress ARP rules in strict tier.

### Rule 14 — Drop Ethernet multicast frames (egress)

```
oifname @wlan vlan id 1641 ether daddr & 01:00:00:00:00:00 == 01:00:00:00:00:00 counter drop
```

Blocks multicast traffic from external sources (other APs, wired devices)
from reaching wireless STAs. IPv6 ND and DHCPv6 multicast replies are
already accepted by the IPv6 rules before this drop.

Rules 13–14 are always generated (regardless of ARP tier), mirroring the
ingress drops. Together with rules 11–12, broadcast and multicast traffic
is blocked in both directions across the bridge.

### IPv6 rules (15–23) — conditional on `ipv6_enabled='1'`

When IPv6 is enabled, 9 rules are inserted between DHCPv4 (9–10)
and the broadcast/multicast drop rules (11–14). They allow IPv6 neighbor
discovery and DHCPv6 traffic, which use multicast MAC addresses that would
otherwise be dropped by rules 12 and 14.

#### Rules 15–16: Router Discovery (SLAAC)

```
iifname @wlan vlan id 1641 ip6 nexthdr icmpv6 icmpv6 type nd-router-solicit counter accept
oifname @wlan vlan id 1641 ip6 nexthdr icmpv6 icmpv6 type nd-router-advert counter accept
```

Router Solicitation (RS, ICMPv6 type 133) is sent by clients to `ff02::2`
(all routers multicast) to discover available gateways. Router Advertisement
(RA, ICMPv6 type 134) is the response from the router containing prefix
information for SLAAC. Both are essential for stateless address
autoconfiguration.

#### Rule 17: ICMPv6 Redirect

```
oifname @wlan vlan id 1641 ip6 nexthdr icmpv6 icmpv6 type nd-redirect counter accept
```

ICMPv6 Redirect (type 137) is sent by routers to inform hosts of a better
first-hop for a destination. Allowed from the router side only.

#### Rules 18–21: Neighbor Discovery (NS/NA)

```
iifname @wlan vlan id 1641 ip6 nexthdr icmpv6 icmpv6 type nd-neighbor-solicit counter accept
oifname @wlan vlan id 1641 ip6 nexthdr icmpv6 icmpv6 type nd-neighbor-solicit counter accept
iifname @wlan vlan id 1641 ip6 nexthdr icmpv6 icmpv6 type nd-neighbor-advert counter accept
oifname @wlan vlan id 1641 ip6 nexthdr icmpv6 icmpv6 type nd-neighbor-advert counter accept
```

Neighbor Solicitation (NS, type 135) resolves an IPv6 address to a MAC address
(equivalent to IPv4 ARP). Neighbor Advertisement (NA, type 136) is the
response. Both directions are allowed for the following reasons:

- Clients need to resolve the gateway's MAC via NS/NA
- The gateway needs to resolve clients' MACs (for reachability)
- Clients need Duplicate Address Detection (DAD) which uses NS with source `::`
- Clients need to respond to the gateway's NS with NA

**Permissive tradeoff:** these rules allow NS/NA between clients, meaning
clients can discover each other's link-layer addresses. However, actual data
exchange between clients remains blocked by rules 11–14 (multicast/broadcast
drop). This matches the IPv4 model where client-to-client unicast is possible
in theory but discovery (ARP) is restricted.

#### Rules 22–23: DHCPv6

```
iifname @wlan vlan id 1641 ip6 nexthdr udp udp sport 546 udp dport 547 counter accept
oifname @wlan vlan id 1641 ip6 nexthdr udp udp sport 547 udp dport 546 counter accept
```

DHCPv6 clients use source port 546 and destination port 547. Servers respond
from 547 to 546. Initial solicit messages may be sent to the multicast
address `ff02::1:2` (All DHCPv6 Relay Agents and Servers), which is why
these rules must come before the multicast drops (rules 12 and 14).

### NPTv6 (Network Prefix Translation)

No bridge-level rules are needed for NPTv6. NPTv6 operates at the
routing/NAT layer (using `ip6tables` SNAT/DNAT or `nft` NAT rules in the
`ip6` family), not the bridge layer. IPv6 unicast traffic between clients
and the gateway already passes through the bridge via the default `accept`
chain policy.

### Rule ordering

The sequence matters:
1. **ARP accept ingress** (rules 1–2) before **ARP drop ingress** (rules 3–4),
   otherwise all ARP from STAs would be dropped before the gateway exception.
2. **ARP accept egress** (rules 5–6) before **ARP drop egress** (rules 7–8) in
   strict tier, otherwise gateway ARP replies/requests to STAs would be blocked.
3. **DHCPv4 accept** (rules 9–10) before **broadcast drops** (rules 11, 13),
   otherwise DHCP broadcasts would be blocked.
4. **IPv6 accept** (rules 15–23) before **multicast drops** (rules 12, 14),
   otherwise IPv6 ND and DHCPv6 multicast traffic would be dropped.
5. Within each group, the more specific match (e.g., ARP request for gateway IP
   from STAs) precedes the broader catch-all (e.g., ether type arp).

### Conditional rules

- **ARP ingress** (rules 1–4) and **ARP egress** (rules 5–8) are generated
  based on the configured tier (see [ARP Filtering Tiers](#arp-filtering-tiers)).
  When `gateway_ip` is not set, no ARP rules are generated.
- **Broadcast/multicast egress** (rules 13–14) are always generated, blocking
  unwanted broadcast and multicast traffic arriving from other bridge ports
  (e.g., other APs on the same L2 segment).
- **IPv6 rules** (15–23) are omitted when `ipv6_enabled` is `0` (the default),
  maintaining full backward compatibility. When enabled, they allow SLAAC,
  DHCPv6, and neighbor discovery traffic through the bridge isolation. NPTv6
  requires no additional bridge rules — it operates at the routing layer.

## Reload Triggers

| Trigger | Mechanism | When it fires |
|---|---|---|
| Wireless UCI change | `procd_add_reload_trigger "wireless"` | `uci commit wireless` + `wifi reload` |
| ap-isolation UCI change | `procd_add_reload_trigger "ap-isolation"` | `uci commit ap-isolation` |
| Interface comes up | Hotplug `/etc/hotplug.d/iface/50-ap-isolation` | `ifup` on `phy*` or `wlan*` devices |

## Usage Examples

Enable isolation on a specific SSID:

```
uci set wireless.wifi_phy1_paw.isolate='1'
uci commit wireless
wifi reload
```

The init script automatically picks up the change and applies bridge-level
rules for the `phy1-paw` interface.

Check whether rules are installed:

```
nft list table bridge ap_isolation
```

Remove rules manually:

```
/etc/init.d/ap-isolation stop
```

Enable and start on boot:

```
/etc/init.d/ap-isolation enable
/etc/init.d/ap-isolation start
```

## License

GPL-2.0-only
