# 落地机代理脚本（landing.sh）

配合 [sbox.sh](./sbox.sh) 的“中转线路管理”使用：在落地机上用一条命令搭好 **SS2022 / SOCKS5 / HTTP** 代理，输出可直接粘贴到中转机 `sbox.sh` 的连接链接。

```text
客户端 ──本机节点──→ 中转机 ─────────────────→ 目标网站（出口 = 中转机）
客户端 ──中转线路──→ 中转机 ──→ 落地机 ─────→ 目标网站（出口 = 落地机）
```

`landing.sh` 只负责在落地机上提供代理；客户端的本机节点和各中转线路节点都由中转机的 `sbox.sh` 生成。

### 三步上手

1. 在**落地机**运行 `landing.sh`，建议开启 SS2022，得到 `ss://...`（或 `socks5://...` / `http://...`）
2. 在**中转机**运行 `sbox.sh`，进入 `9) 中转线路管理` → `1) 添加中转线路`
3. 把落地连接粘贴进去，选择对应落地类型，填写线路名称和端口即可

> **合规提示**：本脚本会搭建代理服务，请仅在合法、授权、合规的环境中使用。完整声明见主 README 的 [免责声明与合规提示](./README.md#免责声明与合规提示)。

---

## 功能

- **SS2022 加密落地**（推荐跨公网使用），支持 `2022-blake3-aes-128-gcm` / `aes-256-gcm` / `chacha20-poly1305`
- 一个端口同时提供 **SOCKS5** 和 **HTTP** 代理（sing-box `mixed` 入站，明文）
- 默认生成随机用户名 / 密码 / SS 密钥，也支持自定义
- 支持 `systemd` / `OpenRC`
- 自动检测公网 IPv4 / IPv6
- 支持 NAT 环境自定义“对外地址 / 对外端口”
- 可选限制来源 IP（ufw / firewalld，TCP + UDP）
- 输出完整链接，直接粘贴到 `sbox.sh` 的中转线路配置：
  - `ss://...`（SS2022，加密）
  - `socks5://user:pass@host:port`（明文）
  - `http://user:pass@host:port`（明文，仅 TCP）

> 落地机只负责提供代理，不参与客户端的 TLS / SNI / 节点链接生成。

> SS2022 和 SOCKS5/HTTP 使用不同端口，因为 sing-box 同一端口不能同时跑不同类型的入站。

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

1. 代理端口（SOCKS5/HTTP 共用，回车随机）
2. 代理用户名（回车用随机值，输入 `-` 关闭认证）
3. 代理密码（回车用随机值）
4. 是否开启 SS2022 落地（推荐 Y）：选端口、加密方式、密钥
5. 对外地址（默认检测到的公网 IP，可填域名 / NAT 映射后的地址）
6. 对外端口（默认等于代理端口，NAT 环境可改）
7. SS2022 对外端口（默认等于 SS 端口）
8. 允许连接的中转机 IP/CIDR（可留空，但建议填写）

SS2022 的密码必须是 base64 编码的 16 字节（aes-128）或 32 字节（aes-256 / chacha20）；脚本会自动生成，直接回车即可。

完成后会输出：

```text
===== 落地连接信息 =====
监听端口：25000
对外地址：1.2.3.4:25000
认证    ：u12ab3 / 8f4c9d2e1a7b6c5d

SOCKS5（支持 TCP + UDP）：
socks5://u12ab3:8f4c9d2e1a7b6c5d@1.2.3.4:25000

HTTP（仅 TCP）：
http://u12ab3:8f4c9d2e1a7b6c5d@1.2.3.4:25000

SS2022（加密传输，推荐）：
ss://MjAyMi1ibGFrZTMtYWVzLTEyOC1nY206Li4u@1.2.3.4:25001#SS2022
  地址  ：1.2.3.4:25001
  加密  ：2022-blake3-aes-128-gcm
  密码  ：Xk3P0mQ9rTk1vH2sLq4WcQ==

把上面的链接粘贴到中转机的 sbox.sh「9) 中转线路管理」中。
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
2. **落地类型**：`1) SOCKS5` / `2) HTTP` / `3) SS2022`
3. **落地连接**：粘贴本脚本输出的 `ss://...`、`socks5://...` 或 `http://...`

   - 粘贴 `ss://` 链接会自动识别加密方式和密码，直接选 `3` 即可
   - 只填 `host:port` 时，SS2022 需要再手动输入加密方式和密码
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
| `ss://...` / `socks5://...` / `http://...` | `landing.sh` | 中转机连接落地机，含密码，仅运维保存 |
| `#HY2_V4` 等本机节点 | `sbox.sh` | 发给客户端，出口为中转机 |
| `#TR_...` 等线路节点 | `sbox.sh` | 发给客户端，出口为该线路的落地机 |

落地连接只用于“中转机 → 落地机”，**不要发给客户端**。

---

## 菜单

```reStructuredText
===== 落地代理（SOCKS5 / HTTP / SS2022）管理脚本 =====
代理端口：25000
对外地址：1.2.3.4:25000
认证    ：u12ab3
SS2022  ：端口 25001（2022-blake3-aes-128-gcm）
1) 重装
2) 查看连接信息
3) 修改 SOCKS5/HTTP 端口
4) 修改用户名 / 密码
5) 修改对外地址
6) 修改来源限制
7) 配置 SS2022
8) 重启服务
9) 卸载
0) 退出
```

SS2022 的端口、加密方式、密钥都在 `7) 配置 SS2022` 里改；不需要 SS2022 时也在这里关闭，脚本会同时移除对应防火墙规则。

---

## 安全建议

- **优先用 SS2022**：它是加密传输，跨公网时不会像 SOCKS5/HTTP 那样暴露密码和目标地址。
- SOCKS5 / HTTP 是**明文协议**，只适合内网 / WireGuard 之类的私有网络。
- 无论用哪种落地，都建议只允许中转机的 IP 访问，不要把端口暴露给所有人。
- 不要关闭认证，除非已经用防火墙严格限制来源。
- SS2022 和 SOCKS5 都支持 TCP + UDP；脚本会同时放行 TCP 和 UDP。
- 云厂商的安全组也需要放行对应端口（脚本只能改本机防火墙）。

脚本会在有 `ufw` / `firewalld` 时尝试添加规则；如果使用云安全组，请手动放行。

---

## 关于 UDP

- **SS2022**：支持 TCP + UDP（标准 Shadowsocks UDP，端口范围由客户端决定）
- **SOCKS5**：支持 TCP + UDP
- **HTTP**：仅支持 TCP

脚本会为 SS2022 / SOCKS5/HTTP 端口同时放行 TCP 和 UDP。如果落地机安全组只放了 TCP，UDP 流量会失败，但 TCP 仍然正常；需要 QUIC / 游戏 / DNS-UDP 时请确认 UDP 已放行。

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

菜单选择 `9) 卸载`，或手动：

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

`landing.sh` 会在服务器上搭建 SS2022 / SOCKS5 / HTTP 代理，属于网络代理与流量中转相关功能。使用前请务必确认：

- 你拥有该服务器、IP、网络和账号的合法所有权，或已获得明确授权
- 你的使用方式符合所在国家 / 地区法律法规，以及云服务商、IDC、ISP 的服务条款
- 不得搭建开放代理，不得用于入侵、扫描、诈骗、钓鱼、攻击、侵权、规避监管或其他违法用途
- SOCKS5 / HTTP 落地是明文传输；跨公网请优先使用 SS2022，或配合私有网络和严格的 IP 白名单
- 本项目按“现状”提供，不附带任何担保；因使用本项目产生的全部法律责任和后果由使用者自行承担

完整声明以主 README 的 [免责声明与合规提示](./README.md#免责声明与合规提示) 为准。本节不构成法律意见，如有疑问请咨询专业律师。

---

## 常见问题

### 1. 中转机连不上落地代理？

检查：

- 落地机安全组 / 防火墙是否放行对应端口（SS2022 是 TCP + UDP）
- 安装时填写的“对外地址 / 对外端口”是否是中转机实际能访问到的地址和端口（NAT 环境尤其注意）
- 用户名密码（或 SS2022 的 method / 密码）是否正确
- 落地机是否限制来源 IP，且已加入中转机 IP

### 2. 为什么同时有 SOCKS5 和 HTTP 两个链接？

落地机使用 sing-box 的 `mixed` 入站，同一个端口同时兼容两种协议。中转机选其中一种即可，它们和 SS2022 是不同端口。

### 3. SS2022 和 SOCKS5 / HTTP 该选哪个？

优先 SS2022：加密传输，密码和目标地址不会明文暴露，跨公网更安全。SOCKS5 / HTTP 适合中转机和落地机在同一个内网 / WireGuard 里的情况。

### 4. 支持 TLS / HTTPS 落地吗？

不提供。需要加密就走 SS2022，它本身是加密协议，不需要额外套 TLS；这样也没有 TLS 握手的额外开销。

### 5. 落地机没有公网 IP 可以吗？

可以，只要中转机能访问到它。把“对外地址 / 对外端口”填成中转机实际访问的地址（例如内网 IP、端口映射后的地址）即可。

### 6. 端口被占用怎么办？

脚本会自动检测本机端口占用，并提示重新输入；也可以直接回车使用随机端口。修改 SS2022 时保留原端口是允许的，不会被“占用”拦住。
