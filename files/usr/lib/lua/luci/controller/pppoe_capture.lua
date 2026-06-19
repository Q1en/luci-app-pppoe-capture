-- luci.controller.pppoe_capture
-- PPPoE 凭证抓取插件的 LuCI 控制器（兼容 OpenWrt 19.07 及更早的 CBI/Legacy 框架）
--
-- 入口菜单：服务 -> PPPoE 凭证抓取

module("luci.controller.pppoe_capture", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/pppoe-capture") then
		return
	end

	-- 服务菜单下注册页面
	entry({"admin", "services", "pppoe_capture"},
		firstchild(), _("PPPoE 凭证抓取"), 60).dependent = false

	-- 状态/操作页面（自定义视图）
	entry({"admin", "services", "pppoe_capture", "main"},
		template("pppoe-capture/pppoe_capture"), _("抓包与解析"), 10).leaf = true

	-- 设置页面（CBI）
	entry({"admin", "services", "pppoe_capture", "settings"},
		cbi("pppoe_capture"), _("设置"), 20).leaf = true

	-- 后台 JSON 接口（AJAX 调用）
	entry({"admin", "services", "pppoe_capture", "api"},
		call("api_action")).leaf = true
end

-- 处理前端 AJAX 请求，调用后端脚本并返回 JSON
function api_action()
	local http = require "luci.http"
	local sys  = require "luci.sys"
	local uci  = require "luci.model.uci".cursor()

	local action = http.formvalue("action") or "status"

	-- 仅允许的动作
	local allowed = { start = true, stop = true, status = true,
	                  parse = true, clean = true, restart = true,
	                  download = true }
	if not allowed[action] then
		http.prepare_content("application/json")
		http.write('{"status":"error","msg":"非法动作"}')
		return
	end

	-- 下载捕获文件：直接以二进制流返回
	if action == "download" then
		local cap_file = "/tmp/pppoe.cap"
		if not nixio.fs.access(cap_file) then
			http.prepare_content("application/json")
			http.write('{"status":"error","msg":"捕获文件不存在"}')
			return
		end
		http.prepare_content("application/vnd.tcpdump.pcap")
		http.header("Content-Disposition",
			'attachment; filename="pppoe.cap"')
		local f = io.open(cap_file, "rb")
		if f then
			http.write(f:read("*a"))
			f:close()
		end
		return
	end

	local script = "/usr/lib/pppoe-capture/pppoe-capture.sh"
	if not nixio.fs.access(script) then
		http.prepare_content("application/json")
		http.write('{"status":"error","msg":"后端脚本不存在"}')
		return
	end

	local out = sys.exec(script .. " " .. action .. " 2>/dev/null")
	http.prepare_content("application/json")
	if out and #out > 0 then
		http.write(out)
	else
		http.write('{"status":"error","msg":"后端无输出"}')
	end
end
