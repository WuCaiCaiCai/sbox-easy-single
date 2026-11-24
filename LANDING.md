# 落地机代理脚本（landing.sh）

配合 [sbox.sh](./sbox.sh) 的“中转模式”使用：在落地机上用一条命令搭好 **SOCKS5 + HTTP** 代理，输出可直接粘贴到中转机 `sbox.sh` 的连接链接。

```text
客户端 ──直连节点──→ 中转机 ─────────────────→ 目标网站（出口 = 中转机）
客户端 ──中转节点──→ 中转机 ──→ 落地机 ─────→ 目标网站（出口 = 落地机）
```

`landing.sh` 只负责在落地机上提供 SOCKS5/HTTP 代理；客户端的两种节点链接都由中转机的 `sbox.sh` 生成。

> **合规提示**：本脚本会搭建代理服务，请仅在合法、授权、合规的环境中使用。完整声明见主 README 的 [免责声明与合规提示](./README.md#免责声明与合规提示)。

---

## 功能

- 一个端口同时提供 **SOCKS5** 和 **HTTP** 代理（sing-box `mixed` 入站）
- 默认生成随机用户名 / 密码，也支持自定义
- 支持 `systemd` / `OpenRC`
- 自动检测公网 IPv4 / IPv6
- 支持 NAT 环境自定义“对外地址 / 对外端口”
- 可选限制来源 IP（ufw / firewalld）
- 输出完整链接，直接粘贴到 `sbox.sh`：
  - `socks5://user:pass@host:port`
  - `http://user:pass@host:port`

> 落地机只负责提供代理，不参与客户端的 TLS / SNI / 节点链接生成。

---

## 支持环境

- Alpine Linux
- Debian / Ubuntu
- CentOS / Rocky / AlmaLinux
- 其他带 `systemd` 或 `OpenRC` 的 Linux

架构：`amd64` / `arm64` / `armv7`。

---

## 快速开始

在**落地机**上以 root 运行：

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/WuCaiCaiCai/sbox-easy-single/main/landing.sh)"
```

或者上传脚本后执行：

```bash
chmod +x landing.sh
sh landing.sh
```

首次运行会依次询问：

1. 代理端口（回车随机）
2. 代理用户名（回车用随机值，输入 `-` 关闭认证）
3. 代理密码（回车用随机值）
4. 对外地址（默认检测到的公网 IP，可填域名 / NAT 映射后的地址）
5. 对外端口（默认等于代理端口，NAT 环境可改）
6. 允许连接的中转机 IP/CIDR（可留空，但建议填写）

完成后会输出：

```text
===== 落地连接信息 =====
监听端口：25000
对外地址：1.2.3.4:25000
认证    ：u12ab3 / 8f4c9d2e1a7b6c5d

SOCKS5（支持 TCP，UDP 取决于落地防火墙）：
socks5://u12ab3:8f4c9d2e1a7b6c5d@1.2.3.4:25000

HTTP（仅 TCP）：
http://u12ab3:8f4c9d2e1a7b6c5d@1.2.3.4:25000

把上面的链接粘贴到中转机的 sbox.sh「中转设置」中。
```

---

## 在中转机上使用

在中转机运行 `sbox.sh`，进入：

```text
9) 中转线路管理
1) 添加中转线路
```

然后按提示配置：

1. **线路名称**：自定义，例如 `TR`、`JP`、`US-West`（不写死地区）
2. **落地类型**：SOCKS5 或 HTTP
3. **落地连接**：粘贴本脚本输出的 `socks5://...` 或 `http://...`
4. **线路端口**：为每个已启用协议分配端口

完成后，中转机会：

- 保留原有的本机直连节点，不变
- 额外生成这条线路的节点，例如：

```text
[V4]           #HY2_V4        → 出口 = 中转机
[V4 中转 TR]   #TR_HY2_V4     → 出口 = TR 落地机
```

如果添加第二条线路 `JP`，会再生成一组：

```text
[V4 中转 JP]   #JP_HY2_V4     → 出口 = JP 落地机
```

可以添加任意多条线路，互不影响。

需要区分：

| 链接 | 生成位置 | 用途 |
| --- | --- | --- |
| `socks5://...` / `http://...` | `landing.sh` | 中转机连接落地机，含密码，仅运维保存 |
| `#HY2_V4` 等本机节点 | `sbox.sh` | 发给客户端，出口为中转机 |
| `#TR_...` 等线路节点 | `sbox.sh` | 发给客户端，出口为该线路的落地机 |

落地连接只用于“中转机 → 落地机”，**不要发给客户端**。

---

## 菜单

```reStructuredText
===== 落地代理（SOCKS5 / HTTP）管理脚本 =====
当前端口：25000
对外地址：1.2.3.4:25000
认证    ：u12ab3
1) 重装
2) 查看连接信息
3) 修改代理端口
4) 修改用户名 / 密码
5) 修改对外地址
6) 修改来源限制
7) 重启服务
8) 卸载
0) 退出
```

---

## 安全建议

落地代理是**明文协议**（SOCKS5 / HTTP），没有 TLS：

- 只允许中转机的 IP 访问，不要把端口暴露给所有人
- 跨公网使用时，建议中转机与落地机之间走私有网络 / WireGuard
- 不要关闭认证，除非已经用防火墙严格限制来源
- 云厂商的安全组也需要放行对应 TCP 端口（脚本只能改本机防火墙）

脚本会在有 `ufw` / `firewalld` 时尝试添加规则；如果使用云安全组，请手动放行。

---

## 关于 UDP

- **SOCKS5**：支持 TCP + UDP
- **HTTP**：仅支持 TCP

SOCKS5 的 UDP 中继使用一个临时 UDP 端口。如果落地机防火墙 / 安全组默认拒绝入站 UDP，UDP 流量会失败，但 TCP 仍然正常。需要 UDP 时：

- 放行落地机的 UDP 中继端口范围，或
- 只在可信网络中使用，或
- 接受 TCP-only

> 如果客户端主要浏览网页（TCP），HTTP 落地也够用；需要 QUIC / 游戏 / DNS-UDP 时请用 SOCKS5，并确认落地放行 UDP。

---

## 默认路径

```reStructuredText
/usr/local/bin/sing-box-landing
/usr/local/lib/libcronet.so
/etc/landing-proxy/config.json
/etc/landing-proxy/state.env
/etc/landing-proxy/info.log
/etc/systemd/system/landing-proxy.service
/etc/init.d/landing-proxy
```

使用独立的二进制名 `sing-box-landing` 和服务名 `landing-proxy`，避免和同机的 `sbox.sh` 冲突。

---

## 卸载

菜单选择 `8) 卸载`，或手动：

```bash
systemctl stop landing-proxy 2>/dev/null || true
systemctl disable landing-proxy 2>/dev/null || true
rm -f /etc/systemd/system/landing-proxy.service
rm -f /usr/local/bin/sing-box-landing
rm -rf /etc/landing-proxy
systemctl daemon-reload 2>/dev/null || true
```

> 卸载不会删除 `/usr/local/lib/libcronet.so`，以免影响同机其他 sing-box 安装。

---

## 免责声明与合规提示

`landing.sh` 会在服务器上搭建 SOCKS5 / HTTP 代理，属于网络代理与流量中转相关功能。使用前请务必确认：

- 你拥有该服务器、IP、网络和账号的合法所有权，或已获得明确授权
- 你的使用方式符合所在国家 / 地区法律法规，以及云服务商、IDC、ISP 的服务条款
- 不得搭建开放代理，不得用于入侵、扫描、诈骗、钓鱼、攻击、侵权、规避监管或其他违法用途
- 落地代理默认是明文传输，请配合私有网络、加密隧道和严格的 IP 白名单
- 本项目按“现状”提供，不附带任何担保；因使用本项目产生的全部法律责任和后果由使用者自行承担

完整声明以主 README 的 [免责声明与合规提示](./README.md#免责声明与合规提示) 为准。本节不构成法律意见，如有疑问请咨询专业律师。

---

## 常见问题

### 1. 中转机连不上落地代理？

检查：

- 落地机安全组 / 防火墙是否放行 TCP 端口
- `EXTERNAL_HOST` / `EXTERNAL_PORT` 是否是中转机实际能访问到的地址和端口（NAT 环境尤其注意）
- 用户名密码是否正确
- 落地机是否限制来源 IP，且已加入中转机 IP

### 2. 为什么同时有 SOCKS5 和 HTTP 两个链接？

落地机使用 sing-box 的 `mixed` 入站，同一个端口同时兼容两种协议。中转机选其中一种即可。

### 3. 支持 TLS / HTTPS 落地吗？

暂不支持。落地脚本提供的是明文 SOCKS5 / HTTP，请配合私有网络或 IP 白名单使用。

### 4. 落地机没有公网 IP 可以吗？

可以，只要中转机能访问到它。把“对外地址 / 对外端口”填成中转机实际访问的地址（例如内网 IP、端口映射后的地址）即可。

### 5. 端口被占用怎么办？

脚本会自动检测本机 TCP 端口占用，并提示重新输入；也可以直接回车使用随机端口。
