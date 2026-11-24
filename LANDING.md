# landing.sh（落地机脚本）

给 `sbox.sh` 的中转线路当出口，落地机跑 SS2022 / SOCKS5 / HTTP。

> 仅限合法、授权、合规的用途。使用前请阅读下面的免责声明。

落地机：

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/WuCaiCaiCai/sbox-easy-single/main/landing.sh)"
```

节点机：

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/WuCaiCaiCai/sbox-easy-single/main/sbox.sh)"
```

装好后在落地机菜单里复制 `ss://` / `socks5://` / `http://` 链接，粘到节点机 `9) 中转线路管理 → 1) 添加中转线路` 即可。

---

## 免责声明与合规提示

`landing.sh` 会在服务器上搭建 SS2022 / SOCKS5 / HTTP 代理，属于网络代理与流量中转相关功能。使用前请务必确认：

- 你拥有该服务器、IP、网络和账号的合法所有权，或已获得明确授权
- 你的使用方式符合所在国家 / 地区法律法规，以及云服务商、IDC、ISP 的服务条款
- 不得搭建开放代理，不得用于入侵、扫描、诈骗、钓鱼、攻击、侵权、规避监管或其他违法用途
- SOCKS5 / HTTP 落地是明文传输；跨公网请优先使用 SS2022，或配合私有网络和严格的 IP 白名单
- 本项目按“现状”提供，不附带任何担保；因使用本项目产生的全部法律责任和后果由使用者自行承担

完整声明见 [README 的免责声明与合规提示](./README.md#免责声明与合规提示)。本节不构成法律意见，如有疑问请咨询专业律师。
