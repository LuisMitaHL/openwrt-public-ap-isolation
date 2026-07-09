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
- Optional IPv6 support: SLAAC (ND), DHCPv6, ICMPv6 redirect passthrough
- Optional VLAN ID and gateway IP via dedicated UCI config
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

With `gateway_ip` and `vlan_id` unset, the script only blocks broadcast and
multicast traffic. Set both values for full client isolation.

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

### Rule 1 — Allow ARP requests for the gateway

```
iifname @wlan vlan id 1641 arp operation request arp daddr ip 10.65.102.1 counter accept
```

Wireless clients need to resolve the gateway's MAC address before they can send
any IP traffic to the internet. This rule permits ARP requests *only* when the
target IP is the configured gateway. All other ARP requests are left to the
drop rules below.

### Rule 2 — Allow ARP replies

```
iifname @wlan vlan id 1641 arp operation reply counter accept
```

ARP replies from the gateway (or any host the gateway proxies for) must reach
the wireless client. This rule accepts all ARP replies on the monitored
interfaces. Combined with rule 1, the only ARP conversation allowed is
client↔gateway.

### Rule 3 — Drop all other ARP

```
iifname @wlan vlan id 1641 ether type arp counter drop
```

Any ARP packet that was not already accepted by rules 1 or 2 must be a
client-to-client ARP. This rule drops it, preventing clients from discovering
each other's MAC addresses at layer 2.

### Rule 4 — Drop VLAN-encapsulated ARP

```
iifname @wlan vlan id 1641 ether type vlan vlan type arp counter drop
```

Same as rule 3 but catches ARP packets inside 802.1Q VLAN tags (double-tagged
or QinQ frames). Without this rule, a malicious client could encapsulate an ARP
probe in a VLAN header to bypass rule 3.

### Rule 5 — Allow DHCP requests (client → server)

```
iifname @wlan vlan id 1641 ip protocol udp udp sport 68 udp dport 67 counter accept
```

DHCP clients use source port 68 and destination port 67 when sending
discover/request messages. This rule allows these messages from wireless
clients to the DHCP server so they can obtain an IP address.

### Rule 6 — Allow DHCP replies (server → client)

```
oifname @wlan vlan id 1641 ip protocol udp udp sport 67 udp dport 68 counter accept
```

DHCP servers respond from port 67 to port 68. The `oifname` keyword matches
the bridge egress port — this allows DHCP offers/acks to reach wireless
clients.

### Rule 7 — Drop Ethernet broadcast frames

```
iifname @wlan vlan id 1641 ether daddr ff:ff:ff:ff:ff:ff counter drop
```

Blocks all Ethernet broadcast frames (destination `ff:ff:ff:ff:ff:ff`). ARP
and DHCP broadcasts are already handled by rules 1–6. This stops any other
broadcast protocols (NetBIOS, mDNS, LLMNR, etc.) from leaking between clients.

### Rule 8 — Drop Ethernet multicast frames

```
iifname @wlan vlan id 1641 ether daddr & 01:00:00:00:00:00 == 01:00:00:00:00:00 counter drop
```

Matches any destination MAC where the first byte's least significant bit is 1
(the multicast/broadcast flag). This catches all multicast traffic (mDNS, UPnP,
IGMP, etc.) except for IPv6 ND and DHCPv6 which are accepted by rules 9–17 when
`ipv6_enabled` is set. Together with rule 7, no group-addressed frame can pass
between wireless clients.

### IPv6 rules (9–17) — conditional on `ipv6_enabled='1'`

When IPv6 is enabled, 9 additional rules are inserted between DHCPv4 (5–6)
and the broadcast/multicast drop rules (7–8). Their purpose is to allow
IPv6 neighbor discovery and DHCPv6 traffic, which use multicast MAC addresses
that would otherwise be dropped by rule 8.

#### Rules 9–10: Router Discovery (SLAAC)

```
iifname @wlan vlan id 1641 ip6 nexthdr icmpv6 icmpv6 type nd-router-solicit counter accept
oifname @wlan vlan id 1641 ip6 nexthdr icmpv6 icmpv6 type nd-router-advert counter accept
```

Router Solicitation (RS, ICMPv6 type 133) is sent by clients to `ff02::2`
(all routers multicast) to discover available gateways. Router Advertisement
(RA, ICMPv6 type 134) is the response from the router containing prefix
information for SLAAC. Both are essential for stateless address
autoconfiguration.

#### Rule 11: ICMPv6 Redirect

```
oifname @wlan vlan id 1641 ip6 nexthdr icmpv6 icmpv6 type nd-redirect counter accept
```

ICMPv6 Redirect (type 137) is sent by routers to inform hosts of a better
first-hop for a destination. Allowed from the router side only.

#### Rules 12–15: Neighbor Discovery (NS/NA)

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
exchange between clients remains blocked by rules 7–8 (multicast/broadcast
drop). This matches the IPv4 model where client-to-client unicast is possible
in theory but discovery (ARP) is restricted.

#### Rules 16–17: DHCPv6

```
iifname @wlan vlan id 1641 ip6 nexthdr udp udp sport 546 udp dport 547 counter accept
oifname @wlan vlan id 1641 ip6 nexthdr udp udp sport 547 udp dport 546 counter accept
```

DHCPv6 clients use source port 546 and destination port 547. Servers respond
from 547 to 546. Initial solicit messages may be sent to the multicast
address `ff02::1:2` (All DHCPv6 Relay Agents and Servers), which is why
these rules must come before the multicast drop (rule 8).

### NPTv6 (Network Prefix Translation)

No bridge-level rules are needed for NPTv6. NPTv6 operates at the
routing/NAT layer (using `ip6tables` SNAT/DNAT or `nft` NAT rules in the
`ip6` family), not the bridge layer. IPv6 unicast traffic between clients
and the gateway already passes through the bridge via the default `accept`
chain policy.

### Rule ordering

The sequence matters:
1. **ARP accept** (rules 1–2) must come before **ARP drop** (rules 3–4),
   otherwise all ARP would be dropped before the gateway exception can match.
2. **DHCP accept** (rules 5–6) must come before **broadcast drop** (rule 7),
   otherwise DHCP broadcasts would be blocked.
3. **IPv6 accept** (rules 9–17) must come before **multicast drop** (rule 8),
   otherwise IPv6 Neighbor Discovery and DHCPv6 multicast traffic would be
   dropped. These rules are only generated when `ipv6_enabled='1'`.
4. Within each group, the more specific match (e.g., ARP request for gateway)
   precedes the broader catch-all (e.g., ether type arp).

### Conditional rules

- **ARP rules** (1–4) are omitted when `gateway_ip` is not configured,
  avoiding broken internet access (clients would have no way to ARP the
  gateway).
- **IPv6 rules** (9–17) are omitted when `ipv6_enabled` is `0` (the default),
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
