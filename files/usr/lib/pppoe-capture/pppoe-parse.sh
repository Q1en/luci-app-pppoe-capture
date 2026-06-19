#!/bin/sh
# pppoe-parse.sh - 解析 PPPoE 捕获文件，提取 PAP/CHAP 凭证
#
# 用法: pppoe-parse.sh <capture_file>
#
# 输出 JSON:
#   {
#     "status": "ok|no_data|error",
#     "msg": "...",
#     "protocol": "PAP|CHAP|unknown",
#     "username": "...",
#     "password": "...",          # PAP 时为明文，CHAP 时为响应哈希
#     "challenge": "...",         # CHAP 时存在
#     "response":  "...",         # CHAP 时存在
#     "chap_id":   "0x..",        # CHAP 时存在
#     "method": "PAP|CHAP"
#   }
#
# 依赖：tcpdump（文本解析回退）；优先使用 tshark（若存在则更可靠）
#       二进制扫描路径需要 bash 的 ${var:off:len} 切片，或 xxd/od
# 作者：pppoe-capture contributors

set -u

CAP_FILE="${1:-/tmp/pppoe.cap}"

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------

json_escape() {
	# 简单的 JSON 字符串转义
	local s="$1"
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	s="${s//$'\n'/\\n}"
	s="${s//$'\r'/}"
	s="${s//$'\t'/\\t}"
	printf '%s' "$s"
}

err() {
	printf '{"status":"error","msg":"%s"}\n' "$(json_escape "$1")"
	exit 1
}

# 把 hex 字符串转换为 ASCII 文本（兼容 busybox）
hex2ascii() {
	local h="$1"
	# 用 sed 把每两个 hex 字符变成 \xHH，再用 printf 还原
	printf '%s' "$h" | sed 's/../\\x&/g' | xargs -0 printf '%b' 2>/dev/null
}

# 读取文件为连续 hex 字符串（优先 xxd，回退 od）
file2hex() {
	local f="$1"
	if command -v xxd >/dev/null 2>&1; then
		xxd -p "$f" 2>/dev/null | tr -d '\n'
	else
		od -An -v -tx1 "$f" 2>/dev/null | tr -d ' \n'
	fi
}

# ---------------------------------------------------------------------------
# tshark 解析路径（最可靠）
# ---------------------------------------------------------------------------
parse_tshark() {
	local f="$1"
	local out user pass

	# PAP: Peer-ID 与 Password 字段
	out=$(tshark -r "$f" -Y "pap.code == 1" -T fields \
		-e pap.peer_id -e pap.password 2>/dev/null | head -n1)

	if [ -n "$out" ]; then
		user="${out%%	*}"
		pass="${out#*	}"
		[ "$pass" = "$out" ] && pass=""
		if [ -n "$user" ]; then
			printf '{"status":"ok","msg":"PAP 凭证已提取","protocol":"PAP","method":"PAP","username":"%s","password":"%s"}\n' \
				"$(json_escape "$user")" "$(json_escape "$pass")"
			return 0
		fi
	fi

	# CHAP: name, challenge, response, identifier
	out=$(tshark -r "$f" -Y "chap.code == 1 || chap.code == 2" -T fields \
		-e chap.identifier -e chap.name -e chap.challenge -e chap.value 2>/dev/null | head -n1)

	if [ -n "$out" ]; then
		local id name challenge response
		id=$(printf '%s' "$out" | cut -f1)
		name=$(printf '%s' "$out" | cut -f2)
		challenge=$(printf '%s' "$out" | cut -f3)
		response=$(printf '%s' "$out" | cut -f4)
		if [ -n "$name" ]; then
			printf '{"status":"ok","msg":"CHAP 凭证已提取 (密码为哈希响应，需离线爆破)","protocol":"CHAP","method":"CHAP","username":"%s","chap_id":"%s","challenge":"%s","response":"%s","password":"%s"}\n' \
				"$(json_escape "$name")" "$(json_escape "$id")" \
				"$(json_escape "$challenge")" "$(json_escape "$response")" \
				"$(json_escape "$response")"
			return 0
		fi
	fi
	return 1
}

# ---------------------------------------------------------------------------
# tcpdump 文本预检 + 二进制解析路径
# ---------------------------------------------------------------------------
parse_tcpdump() {
	local f="$1"
	local txt

	# 用 tcpdump 输出 ASCII 预检是否存在 PAP/CHAP 报文
	txt=$(tcpdump -r "$f" -nn -A -e 2>/dev/null)

	if [ -z "$txt" ]; then
		printf '{"status":"no_data","msg":"捕获文件无法读取或无 PPPoE 数据"}\n'
		return 0
	fi

	# PAP 路径
	if printf '%s' "$txt" | grep -qi 'pap'; then
		parse_pap_binary "$f" && return 0
	fi

	# CHAP 路径
	if printf '%s' "$txt" | grep -qi 'chap'; then
		parse_chap_binary "$f" && return 0
	fi

	printf '{"status":"no_data","msg":"未发现 PAP/CHAP 认证报文，请确认旧路由器已触发拨号"}\n'
	return 0
}

# 从 pcap 文件中按字节扫描 PAP Authenticate-Request
# PPPoE Session (0x8864) 之内，PPP Protocol = 0xc023 (PAP)
# PAP 报文: code(1) id(1) length(2) peer_id_len(1) peer_id(n) passwd_len(1) passwd(m)
parse_pap_binary() {
	local f="$1"

	# 需要子串切片能力（bash）或 xxd
	if ! command -v bash >/dev/null 2>&1 && ! command -v xxd >/dev/null 2>&1; then
		return 1
	fi

	local hex
	hex=$(file2hex "$f")
	[ -z "$hex" ] && return 1

	# 查找 PPP PAP 协议头 c023 + code 01 (Auth-Request)
	local idx
	idx=$(printf '%s' "$hex" | grep -bo "c02301" | head -n1 | cut -d: -f1)
	[ -z "$idx" ] && return 1

	# 截取 PAP 负载（跳过 c023 4 个 hex 字符）
	local pap
	if command -v bash >/dev/null 2>&1; then
		pap="${hex:$((idx+4))}"
	else
		# 用 cut/awk 实现：每 2 字符为 1 字节
		pap=$(printf '%s' "$hex" | cut -c$((idx+5))-)
	fi

	# PAP 字段解析
	local code id len peer_len_hex peer_len
	code="${pap:0:2}"
	id="${pap:2:2}"
	len="${pap:4:4}"
	peer_len_hex="${pap:8:2}"
	[ -z "$peer_len_hex" ] && return 1
	peer_len=$(( 16#$peer_len_hex ))
	[ "$peer_len" -le 0 ] 2>/dev/null && return 1

	# peer_id 起始 hex 偏移: 10
	local peer_hex username
	peer_hex="${pap:10:$((peer_len*2))}"
	username=$(hex2ascii "$peer_hex")

	# password
	local pw_off pw_len_hex pw_len pass_hex password
	pw_off=$(( 10 + peer_len*2 ))
	pw_len_hex="${pap:$pw_off:2}"
	pw_len=0
	[ -n "$pw_len_hex" ] && pw_len=$(( 16#$pw_len_hex ))
	pass_hex="${pap:$((pw_off+2)):$((pw_len*2))}"
	if [ "$pw_len" -gt 0 ] 2>/dev/null; then
		password=$(hex2ascii "$pass_hex")
	else
		password=""
	fi

	if [ -n "$username" ]; then
		printf '{"status":"ok","msg":"PAP 凭证已提取","protocol":"PAP","method":"PAP","username":"%s","password":"%s","chap_id":"0x%s"}\n' \
			"$(json_escape "$username")" "$(json_escape "$password")" "$id"
		return 0
	fi
	return 1
}

# 从 pcap 文件中按字节扫描 CHAP Challenge / Response
# PPP 协议 0xc223 (CHAP)
# CHAP: code(1) id(1) length(2) value_size(1) value(n) name(m)
parse_chap_binary() {
	local f="$1"

	if ! command -v bash >/dev/null 2>&1 && ! command -v xxd >/dev/null 2>&1; then
		return 1
	fi

	local hex
	hex=$(file2hex "$f")
	[ -z "$hex" ] && return 1

	# 查找 CHAP 协议头 c223 + code 01 (Challenge) 或 02 (Response)
	# 先尝试 Challenge (01)，再尝试 Response (02)
	local idx code_offset pat
	for pat in "c22301" "c22302"; do
		idx=$(printf '%s' "$hex" | grep -bo "$pat" | head -n1 | cut -d: -f1)
		[ -n "$idx" ] && break
	done
	[ -z "$idx" ] && return 1

	local chap
	if command -v bash >/dev/null 2>&1; then
		chap="${hex:$((idx+4))}"
	else
		chap=$(printf '%s' "$hex" | cut -c$((idx+5))-)
	fi

	local code id len vsize_hex vsize
	code="${chap:0:2}"
	id="${chap:2:2}"
	len="${chap:4:4}"
	vsize_hex="${chap:8:2}"
	[ -z "$vsize_hex" ] && return 1
	vsize=$(( 16#$vsize_hex ))
	[ "$vsize" -le 0 ] 2>/dev/null && return 1

	local value_hex name_off name_len name_hex name
	value_hex="${chap:10:$((vsize*2))}"
	name_off=$(( 10 + vsize*2 ))
	local total_len=0
	[ -n "$len" ] && total_len=$(( 16#$len ))
	name_len=$(( total_len - 5 - vsize ))   # 5 = code+id+len(2)+vsize
	[ "$name_len" -lt 0 ] && name_len=0
	name_hex="${chap:$name_off:$((name_len*2))}"
	name=$(hex2ascii "$name_hex")

	local code_desc
	case "$code" in
		01) code_desc="Challenge" ;;
		02) code_desc="Response" ;;
		*)  code_desc="code=$code" ;;
	esac

	# 尝试继续查找 Response 报文以获取响应哈希
	local response_hex="" rest ridx
	rest="${hex:$((idx+6))}"
	ridx=$(printf '%s' "$rest" | grep -bo "c22302" | head -n1 | cut -d: -f1)
	if [ -n "$ridx" ]; then
		local rchap rsize_hex rsize
		if command -v bash >/dev/null 2>&1; then
			rchap="${rest:$((ridx+4))}"
		else
			rchap=$(printf '%s' "$rest" | cut -c$((ridx+5))-)
		fi
		rsize_hex="${rchap:8:2}"
		if [ -n "$rsize_hex" ]; then
			rsize=$(( 16#$rsize_hex ))
			[ "$rsize" -gt 0 ] 2>/dev/null && response_hex="${rchap:10:$((rsize*2))}"
		fi
	fi

	if [ -n "$name" ]; then
		printf '{"status":"ok","msg":"CHAP 凭证已提取 (密码字段为哈希响应，需离线爆破还原)","protocol":"CHAP","method":"CHAP","username":"%s","chap_id":"0x%s","challenge":"%s","response":"%s","password":"%s","code":"%s"}\n' \
			"$(json_escape "$name")" "$id" \
			"$(json_escape "$value_hex")" \
			"$(json_escape "$response_hex")" \
			"$(json_escape "$response_hex")" \
			"$code_desc"
		return 0
	fi
	return 1
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

if [ ! -f "$CAP_FILE" ]; then
	printf '{"status":"no_data","msg":"捕获文件不存在: %s"}\n' "$(json_escape "$CAP_FILE")"
	exit 0
fi

# 文件过小则认为无有效数据
size=$(wc -c < "$CAP_FILE" 2>/dev/null || echo 0)
if [ "$size" -lt 24 ] 2>/dev/null; then
	printf '{"status":"no_data","msg":"捕获文件为空或过小 (%s 字节)"}\n' "$size"
	exit 0
fi

# 优先尝试 tshark（结果最可靠）
if command -v tshark >/dev/null 2>&1; then
	parse_tshark "$CAP_FILE" && exit 0
fi

# 退回到 tcpdump 文本/二进制解析
parse_tcpdump "$CAP_FILE"
exit 0
