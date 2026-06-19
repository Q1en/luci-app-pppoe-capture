-- luci.model.cbi.pppoe_capture
-- PPPoE 凭证抓取插件的设置页面（CBI）

local m = Map("pppoe-capture", translate("PPPoE 凭证抓取 - 设置"),
	translate("配置抓包所用的网络接口与超时参数。"
		.. "默认抓包接口为 br-lan，请将旧路由器的 WAN 口用网线连接到该接口所在的 LAN 口。"))

local s = m:section(TypedSection, "global", translate("全局设置"))
s.addremove = false
s.anonymous = true

local iface = s:option(Value, "iface", translate("抓包接口"))
iface.default = "br-lan"
iface.rmempty = false
iface.description = translate("监听 PPPoE 报文的网络接口，例如 br-lan、eth0、wlan0 等。"
	.. "请确保旧路由器 WAN 口通过网线连接到该接口。")

-- 列举系统接口供下拉选择
local sys = require "luci.sys"
local ifaces = sys.exec("ip -o link show | awk -F': ' '{print $2}' 2>/dev/null")
if ifaces and #ifaces > 0 then
	local iface_values = {}
	for line in ifaces:gmatch("[^\n]+") do
		line = line:gsub("^%s+", ""):gsub("%s+$", "")
		if line ~= "" then
			iface_values[#iface_values+1] = line
		end
	end
	if #iface_values > 0 then
		local sel = s:option(ListValue, "iface_sel", translate("或从列表选择接口"))
		sel.optional = true
		sel:value("", translate("-- 手动输入 --"))
		for _, v in ipairs(iface_values) do
			sel:value(v, v)
		end
		-- 当从列表选择时，写回 iface
		sel.write = function(self, section, value)
			if value and #value > 0 then
				iface:write(section, value)
			end
		end
		sel.cfgvalue = function(self, section)
			return iface:cfgvalue(section) or ""
		end
	end
end

local duration = s:option(Value, "duration", translate("抓包时长 (秒)"))
duration.default = "0"
duration.datatype = "uinteger"
duration.description = translate("0 表示持续抓包直到手动点击“停止抓包”。"
	.. "设置大于 0 的值后，抓包到达指定秒数会自动停止并解析。")

local maxpkts = s:option(Value, "max_packets", translate("最大抓包数"))
maxpkts.default = "0"
maxpkts.datatype = "uinteger"
maxpkts.description = translate("0 表示不限包数。设置大于 0 的值后，捕获到指定数量的包后自动停止。")

return m
