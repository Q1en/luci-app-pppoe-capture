# luci-app-pppoe-capture

OpenWrt LuCI 插件 —— **PPPoE 凭证抓取**

把 OpenWrt 路由器伪装成运营商侧设备，截获旧路由器 PPPoE 拨号报文，
**自动解析 PAP/CHAP 认证信息**，提取明文宽带账号与密码。

> 等价于手工执行 `tcpdump -i br-lan -w /tmp/pppoe.cap pppd or pppoe` 并用 Wireshark 分析，
> 但全部流程在路由器本地一键完成，无需电脑即可看到结果。

---

## 工作原理

1. 旧路由器 WAN 口通过网线连接到 OpenWrt 的 LAN 口（默认监听 `br-lan`）。
2. 插件在该接口启动 `tcpdump`，过滤 PPPoE Discovery / Session 与 PPP PAP/CHAP 报文。
3. 旧路由器发起 PPPoE 拨号时，其 `Authenticate-Request` 报文被捕获到 `/tmp/pppoe.cap`。
4. 后端解析脚本读取 pcap：
   - **PAP**：直接提取 **明文账号 + 明文密码**。
   - **CHAP**：提取 **账号 + Challenge + Response 哈希**（需离线爆破还原密码）。
5. 结果以 JSON 返回给 LuCI Web 界面展示，并支持下载 `.cap` 文件用 Wireshark 复核。

---

## 文件结构

```
luci-app-pppoe-capture/
├── Makefile                                          # OpenWrt 包构建文件
├── README.md
└── files/
    ├── etc/
    │   ├── config/pppoe-capture                      # UCI 配置（接口/时长/包数）
    │   └── uci-defaults/luci-app-pppoe-capture       # 安装时初始化配置
    └── usr/
        ├── lib/
        │   ├── lua/luci/
        │   │   ├── controller/pppoe_capture.lua      # LuCI 控制器 + JSON API
        │   │   └── model/cbi/pppoe_capture.lua       # 设置页面 (CBI)
        │   └── pppoe-capture/
        │       ├── pppoe-capture.sh                  # 抓包控制脚本 (start/stop/...)
        │       └── pppoe-parse.sh                    # pcap 解析脚本 (PAP/CHAP)
        └── share/
            ├── luci/
            │   ├── menu.d/luci-app-pppoe-capture.json # 新版 LuCI 菜单注册
            │   └── template/pppoe-capture/
            │       └── pppoe_capture.htm             # 主操作页面视图
            └── rpcd/acl.d/luci-app-pppoe-capture.json # rpcd 访问控制
```

---

## 依赖

- `tcpdump`（核心抓包工具，Makefile 已声明依赖）
- `luci-base` / `luci-compat`（Web 界面）
- `bash`（解析脚本使用 bash 语法；OpenWrt 默认 ash 也可，但建议安装 bash 以确保子串切片等特性可用）

可选（增强解析可靠性）：

- `tshark`：若安装，解析脚本优先使用 tshark，结果更准确。
- `xxd`：用于二进制 pcap 字节扫描；busybox 的 `od` 可作为回退。

---

## 编译与安装

### 方式一：在 OpenWrt 源码树中编译（推荐）

```bash
# 1. 准备 OpenWrt SDK / 源码树
git clone https://git.openwrt.org/openwrt/openwrt.git
cd openwrt
./scripts/feeds update -a
./scripts/feeds install -a

# 2. 把本插件放入 package 目录
git clone <本仓库> package/luci-app-pppoe-capture

# 3. 选中插件
make menuconfig
#   LuCI  ->  3. Applications  ->  <*> luci-app-pppoe-capture

# 4. 编译
make package/luci-app-pppoe-capture/compile V=s

# 产物：bin/packages/<arch>/luci/luci-app-pppoe-capture_*.ipk
```

### 方式二：直接在路由器上安装依赖并手动部署

若无编译环境，可在已运行的 OpenWrt 上手动安装：

```bash
# 安装依赖
opkg update
opkg install tcpdump luci luci-compat bash

# 将 files/ 目录下的文件按原路径复制到路由器对应位置
# 然后赋予脚本可执行权限
chmod +x /usr/lib/pppoe-capture/pppoe-capture.sh
chmod +x /usr/lib/pppoe-capture/pppoe-parse.sh
chmod +x /etc/uci-defaults/luci-app-pppoe-capture
/etc/uci-defaults/luci-app-pppoe-capture
rm -f /etc/uci-defaults/luci-app-pppoe-capture
/etc/init.d/rpcd restart
rm -f /tmp/luci-indexcache
```

---

## 使用方法

### Web 界面（LuCI）

1. 登录 OpenWrt 后台，进入 **服务 → PPPoE 凭证抓取**。
2. 在 **设置** 标签页选择监听接口（默认 `br-lan`），保存。
3. 用网线连接：**旧路由器 WAN 口 ↔ OpenWrt LAN 口**。
4. 回到 **抓包与解析** 标签页，点击 **开始抓包**。
5. 重启旧路由器，或在其后台触发 PPPoE 拨号。
6. 等待几秒，点击 **停止抓包并解析**（或 **立即解析**）。
7. 页面下方即显示 **认证协议 / 宽带账号 / 密码（或 CHAP 哈希）**。
8. 可点击 **下载** 获取 `/tmp/pppoe.cap`，用 Wireshark 复核（过滤 `pap` 或 `chap`）。

### 命令行（SSH）

```bash
# 启动抓包（接口取自 UCI 配置）
/usr/lib/pppoe-capture/pppoe-capture.sh start

# 查看状态
/usr/lib/pppoe-capture/pppoe-capture.sh status

# 停止并自动解析
/usr/lib/pppoe-capture/pppoe-capture.sh stop

# 仅解析当前捕获文件
/usr/lib/pppoe-capture/pppoe-capture.sh parse

# 单独对一个 pcap 文件解析
/usr/lib/pppoe-capture/pppoe-parse.sh /tmp/pppoe.cap

# 清理
/usr/lib/pppoe-capture/pppoe-capture.sh clean
```

UCI 配置示例：

```bash
uci set pppoe-capture.@global[0].iface='eth0'
uci set pppoe-capture.@global[0].duration='60'    # 60 秒后自动停止
uci set pppoe-capture.@global[0].max_packets='0'  # 不限包数
uci commit pppoe-capture
```

---

## 输出说明

### PAP（明文密码）

```json
{
  "status": "ok",
  "protocol": "PAP",
  "username": "0123456789",
  "password": "yourpassword"
}
```

### CHAP（哈希响应，需爆破）

```json
{
  "status": "ok",
  "protocol": "CHAP",
  "username": "0123456789",
  "chap_id": "0x01",
  "challenge": "a1b2c3...",
  "response": "d4e5f6..."
}
```

CHAP 协议不传输明文密码，需在电脑上用 `hashcat -m 5500` / `asleap` / `john` 等工具
对 `challenge:response` 离线爆破还原原密码。

---

## PAP 与 CHAP 的区别

| 协议 | 密码传输 | 能否直接看到密码 |
|------|----------|------------------|
| PAP  | **明文** | ✅ 是 |
| CHAP | 哈希响应（MD5） | ❌ 否，需离线爆破 |

多数国内运营商默认使用 PAP，因此通常能直接获得明文密码。
若对端协商为 CHAP，插件会提示并给出 `challenge` / `response` 哈希。

---

## 常见问题

**Q: 点击"开始抓包"提示 tcpdump 未安装？**
A: 在 系统 → 软件包 中安装 `tcpdump`，或在命令行 `opkg update && opkg install tcpdump`。

**Q: 抓包后解析显示"未发现 PAP/CHAP 认证报文"？**
A: 说明旧路由器未真正发起拨号。请确认：
- 网线确实连在旧路由器 **WAN 口** 与 OpenWrt **LAN 口** 之间；
- 监听接口选择正确（在 **设置** 中更改）；
- 旧路由器已重启或手动触发拨号。

**Q: CHAP 模式拿到的不是明文密码？**
A: 这是 CHAP 协议本身的设计。将 `challenge` 和 `response` 拷到电脑，
用 `hashcat -m 5500 <user>::<response>:<challenge>` 爆破。

**Q: 解析脚本报子串切片错误？**
A: `pppoe-parse.sh` 的二进制解析路径依赖 bash 的 `${var:offset:length}` 切片。
请安装 bash：`opkg install bash`，或安装 `tshark` 走更可靠的解析路径。

---

## 法律与道德声明

本工具仅用于 **找回自己合法拥有的宽带凭证**（例如旧路由器遗忘密码时）。
禁止用于任何未经授权的网络窃听或攻击行为。使用者须自行承担法律责任。
