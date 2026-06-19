#!/bin/sh
# pppoe-capture.sh - PPPoE 拨号抓包控制脚本
#
# 功能：
#   start   在指定接口上启动 tcpdump 抓取 PPPoE/PAP/CHAP 报文
#   stop    停止正在运行的 tcpdump，并自动解析捕获文件
#   status  查询抓包状态（running / idle / error）
#   parse   立即解析当前捕获文件
#   clean   停止抓包并清理捕获文件
#   restart 停止后重新启动
#
# 依赖：tcpdump
# 作者：pppoe-capture contributors

set -u

CAP_DIR="/tmp"
CAP_FILE="${CAP_DIR}/pppoe.cap"
PID_FILE="/var/run/pppoe-capture.pid"
LOG_FILE="${CAP_DIR}/pppoe-capture.log"

# 默认接口，可被 UCI 配置覆盖
IFACE="br-lan"
DURATION=0      # 0 表示持续抓包直到手动停止
MAX_PKTS=0      # 0 表示不限包数

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------

# 简单 JSON 字符串转义
jesc() {
	local s="$1"
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	s="${s//$'\n'/\\n}"
	s="${s//$'\r'/}"
	s="${s//$'\t'/\\t}"
	printf '%s' "$s"
}

log() {
	local msg="$1"
	logger -t pppoe-capture "$msg"
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

# 读取 UCI 配置
load_config() {
	local v
	v=$(uci -q get pppoe-capture.@global[0].iface 2>/dev/null) && [ -n "$v" ] && IFACE="$v"
	v=$(uci -q get pppoe-capture.@global[0].duration 2>/dev/null) && [ -n "$v" ] && DURATION="$v"
	v=$(uci -q get pppoe-capture.@global[0].max_packets 2>/dev/null) && [ -n "$v" ] && MAX_PKTS="$v"
}

# 判断 tcpdump 是否已安装
check_deps() {
	if ! command -v tcpdump >/dev/null 2>&1; then
		log "ERROR: tcpdump 未安装，请在 系统->软件包 中安装 tcpdump"
		printf '{"status":"error","msg":"tcpdump 未安装"}'
		return 1
	fi
	return 0
}

is_running() {
	[ -f "$PID_FILE" ] || return 1
	local pid
	pid=$(cat "$PID_FILE" 2>/dev/null)
	[ -n "$pid" ] || return 1
	kill -0 "$pid" 2>/dev/null
}

file_size() {
	local f="$1"
	[ -f "$f" ] || { echo 0; return; }
	wc -c < "$f" 2>/dev/null | tr -d ' ' || echo 0
}

# ---------------------------------------------------------------------------
# 主操作
# ---------------------------------------------------------------------------

start() {
	load_config
	check_deps || return 1

	if is_running; then
		printf '{"status":"running","msg":"已经在抓包中","iface":"%s"}' "$(jesc "$IFACE")"
		return 0
	fi

	# 检查接口是否存在
	if ! ip link show "$IFACE" >/dev/null 2>&1; then
		log "ERROR: 接口 $IFACE 不存在"
		printf '{"status":"error","msg":"接口 %s 不存在"}' "$(jesc "$IFACE")"
		return 1
	fi

	# 清理旧文件
	rm -f "$CAP_FILE" "$LOG_FILE"

	# 构造 tcpdump 参数：抓取 PPPoE Discovery 与 Session 阶段，以及 PPP PAP/CHAP
	local filter='pppoed or pppoes or (ppp and (pap or chap))'

	local opts="-i $IFACE -w $CAP_FILE -U -s 0"
	if [ "$MAX_PKTS" -gt 0 ] 2>/dev/null; then
		opts="$opts -c $MAX_PKTS"
	fi

	if [ "$DURATION" -gt 0 ] 2>/dev/null; then
		log "启动抓包：接口=$IFACE 时长=${DURATION}s 文件=$CAP_FILE"
		timeout "${DURATION}" tcpdump $opts "$filter" >>"$LOG_FILE" 2>&1 &
	else
		log "启动抓包：接口=$IFACE 文件=$CAP_FILE (持续直到 stop)"
		tcpdump $opts "$filter" >>"$LOG_FILE" 2>&1 &
	fi

	local pid=$!
	echo "$pid" > "$PID_FILE"

	sleep 1
	if is_running; then
		printf '{"status":"running","msg":"抓包已启动，请在旧路由器上触发拨号","iface":"%s","file":"%s"}' \
			"$(jesc "$IFACE")" "$(jesc "$CAP_FILE")"
	else
		log "ERROR: tcpdump 启动失败"
		rm -f "$PID_FILE"
		printf '{"status":"error","msg":"tcpdump 启动失败，请查看日志"}'
		return 1
	fi
}

stop() {
	if ! is_running; then
		rm -f "$PID_FILE"
		printf '{"status":"idle","msg":"没有正在运行的抓包"}'
		return 0
	fi

	local pid
	pid=$(cat "$PID_FILE")
	kill "$pid" 2>/dev/null || true
	for _ in 1 2 3 4 5; do
		kill -0 "$pid" 2>/dev/null || break
		sleep 0.2
	done
	kill -9 "$pid" 2>/dev/null || true
	rm -f "$PID_FILE"

	log "抓包已停止"

	if [ -f "$CAP_FILE" ]; then
		local parse_out size
		parse_out=$(/usr/lib/pppoe-capture/pppoe-parse.sh "$CAP_FILE" 2>/dev/null || true)
		size=$(file_size "$CAP_FILE")
		if [ -n "$parse_out" ]; then
			# 将解析结果嵌入 result 字段（parse_out 本身是合法 JSON 对象）
			printf '{"status":"idle","msg":"抓包已停止","file":"%s","size":%s,"result":%s}' \
				"$(jesc "$CAP_FILE")" "$size" "$parse_out"
		else
			printf '{"status":"idle","msg":"抓包已停止","file":"%s","size":%s,"result":{"status":"no_data","msg":"未解析到凭证"}}' \
				"$(jesc "$CAP_FILE")" "$size"
		fi
	else
		printf '{"status":"idle","msg":"抓包已停止，但未生成捕获文件"}'
	fi
}

status() {
	if is_running; then
		local pid size
		pid=$(cat "$PID_FILE")
		size=$(file_size "$CAP_FILE")
		printf '{"status":"running","iface":"%s","file":"%s","size":%s,"pid":%s}' \
			"$(jesc "$IFACE")" "$(jesc "$CAP_FILE")" "$size" "$pid"
	else
		rm -f "$PID_FILE" 2>/dev/null
		local size
		size=$(file_size "$CAP_FILE")
		printf '{"status":"idle","file":"%s","size":%s}' \
			"$(jesc "$CAP_FILE")" "$size"
	fi
}

# 立即解析当前捕获文件（无需停止抓包）
parse() {
	if [ ! -f "$CAP_FILE" ]; then
		printf '{"status":"no_data","msg":"尚无捕获文件"}'
		return 1
	fi
	/usr/lib/pppoe-capture/pppoe-parse.sh "$CAP_FILE"
}

# 清理捕获文件
clean() {
	stop >/dev/null 2>&1
	rm -f "$CAP_FILE" "$LOG_FILE"
	printf '{"status":"idle","msg":"已清理捕获文件"}'
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

case "${1:-help}" in
	start)   start ;;
	stop)    stop ;;
	status)  status ;;
	parse)   parse ;;
	clean)   clean ;;
	restart) stop; sleep 1; start ;;
	help|*)
		echo "用法: $0 {start|stop|status|parse|clean|restart}"
		;;
esac
