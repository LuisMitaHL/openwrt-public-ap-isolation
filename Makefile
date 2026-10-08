include $(TOPDIR)/rules.mk

PKG_NAME:=ap-isolation
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=changeme
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/ap-isolation
  SECTION:=net
  CATEGORY:=Network
  TITLE:=AP Client Isolation via nftables
  DEPENDS:=+nftables
  PKGARCH:=all
endef

define Package/ap-isolation/description
  Implements client isolation on public Wi-Fi access points using nftables.
  Reads UCI wireless config to determine which interfaces need isolation,
  and applies bridge-level nftables rules.

  Two tiers via the 'mode' option:
    filter  - filters ARP, broadcast and multicast between clients (default);
    gateway - default-drop gateway allowlist: clients may only exchange
              traffic with the configured main router.
endef

define Build/Compile
endef

define Package/ap-isolation/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_DIR) $(1)/etc/hotplug.d/net

	$(INSTALL_CONF) ./files/etc/config/ap-isolation $(1)/etc/config/ap-isolation
	$(INSTALL_BIN) ./files/etc/init.d/ap-isolation $(1)/etc/init.d/ap-isolation
	$(INSTALL_BIN) ./files/usr/sbin/ap-isolation.sh $(1)/usr/sbin/ap-isolation.sh
	$(INSTALL_DATA) ./files/etc/hotplug.d/net/50-ap-isolation $(1)/etc/hotplug.d/net/50-ap-isolation
endef

# Separate add-on, selected only where the qca8k switch driver is in use
# (e.g. the ipq40xx MikroTik cAP ac). Installed but inert until
# ap-isolation.settings.fdb_workaround='1'.
define Package/ap-isolation-fdb
  SECTION:=net
  CATEGORY:=Network
  TITLE:=qca8k stale-ATU roaming workaround (ap-isolation add-on)
  DEPENDS:=+ap-isolation +iw
endef

define Package/ap-isolation-fdb/description
  Opt-in workaround for the qca8k stale-ATU roaming blackhole
  (openwrt/openwrt#25365). Pins a static bridge FDB entry on a station's
  wireless interface at association and removes it on disassociation, which
  purges the stale hardware ATU entry left on the wired uplink after a roam.
  Disabled by default: set ap-isolation.settings.fdb_workaround='1'. Only
  meaningful on qca8k targets; select it explicitly per device.
endef

define Package/ap-isolation-fdb/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/ap-isolation-fdb $(1)/usr/sbin/ap-isolation-fdb
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/ap-isolation-fdb $(1)/etc/init.d/ap-isolation-fdb
endef

$(eval $(call BuildPackage,ap-isolation))
$(eval $(call BuildPackage,ap-isolation-fdb))
