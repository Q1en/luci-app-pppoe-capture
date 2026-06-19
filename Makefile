# luci-app-pppoe-capture - OpenWrt PPPoE 凭证抓取插件
#
# 自动化 PPPoE 拨号抓包并解析 PAP/CHAP 认证报文，提取宽带账号与密码。

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-pppoe-capture
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0
PKG_MAINTAINER:=pppoe-capture contributors

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
	SECTION:=luci
	CATEGORY:=LuCI
	SUBMENU:=3. Applications
	TITLE:=PPPoE 凭证抓取插件
	DEPENDS:=+tcpdump +luci-base +luci-compat +bash
	PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
	通过在 OpenWrt 上运行 tcpdump 抓取旧路由器 PPPoE 拨号报文，
	自动解析 PAP/CHAP 认证信息，提取明文宽带账号与密码，
	并提供 LuCI Web 界面操作与结果展示。
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DIR) $(1)/usr/share/luci/template/pppoe-capture
	$(INSTALL_DIR) $(1)/usr/lib/pppoe-capture
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/uci-defaults

	# 后端脚本
	$(INSTALL_BIN) ./files/usr/lib/pppoe-capture/pppoe-capture.sh \
		$(1)/usr/lib/pppoe-capture/pppoe-capture.sh
	$(INSTALL_BIN) ./files/usr/lib/pppoe-capture/pppoe-parse.sh \
		$(1)/usr/lib/pppoe-capture/pppoe-parse.sh

	# 配置文件
	$(INSTALL_DATA) ./files/etc/config/pppoe-capture \
		$(1)/etc/config/pppoe-capture

	# UCI defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/luci-app-pppoe-capture \
		$(1)/etc/uci-defaults/luci-app-pppoe-capture

	# LuCI 控制器 (兼容 19.07 及更早)
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/controller/pppoe_capture.lua \
		$(1)/usr/lib/lua/luci/controller/pppoe_capture.lua

	# LuCI CBI model (兼容旧版)
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/model/cbi/pppoe_capture.lua \
		$(1)/usr/lib/lua/luci/model/cbi/pppoe_capture.lua

	# LuCI 模板视图
	$(INSTALL_DATA) ./files/usr/share/luci/template/pppoe-capture/pppoe_capture.htm \
		$(1)/usr/share/luci/template/pppoe-capture/pppoe_capture.htm

	# LuCI JS 菜单 (新版 LuCI)
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-pppoe-capture.json \
		$(1)/usr/share/luci/menu.d/luci-app-pppoe-capture.json

	# rpcd ACL
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-pppoe-capture.json \
		$(1)/usr/share/rpcd/acl.d/luci-app-pppoe-capture.json
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	( . /etc/uci-defaults/luci-app-pppoe-capture ) && rm -f /etc/uci-defaults/luci-app-pppoe-capture
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
	rm -f /tmp/luci-indexcache 2>/dev/null || true
}
exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
	rm -f /tmp/luci-indexcache 2>/dev/null || true
}
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
