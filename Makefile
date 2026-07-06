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
  and applies bridge-level nftables rules to block ARP, broadcast, and
  multicast traffic between clients while allowing DHCP and gateway ARP.
endef

define Build/Compile
endef

define Package/ap-isolation/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface

	$(INSTALL_CONF) ./files/etc/config/ap-isolation $(1)/etc/config/ap-isolation
	$(INSTALL_BIN) ./files/etc/init.d/ap-isolation $(1)/etc/init.d/ap-isolation
	$(INSTALL_BIN) ./files/usr/sbin/ap-isolation.sh $(1)/usr/sbin/ap-isolation.sh
	$(INSTALL_DATA) ./files/etc/hotplug.d/iface/50-ap-isolation $(1)/etc/hotplug.d/iface/50-ap-isolation
endef

$(eval $(call BuildPackage,ap-isolation))
