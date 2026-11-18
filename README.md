# bt77-acme-fix

给 **宝塔面板 7.7.0** 用的安装后体检与修复脚本。

7.7.0 有个证书续期的坑，要等好几个月才暴露：**Let's Encrypt 续签是成功的、新证书也下载下来了，但 nginx 一直在发那张过期证书**。面板日志写着"续签成功"，只有手动去点一次才对。这个脚本能把这种状态查出来，把两处导致问题的代码打上补丁，把漏掉的部署补回去，顺便把新装机器的其他坑一起报出来。

```
check    只读体检，生产环境可以直接跑
fix      打补丁 + 补续签任务 + 把漂移的证书重新部署
harden   可选加固：面板端口、IP 白名单、BasicAuth、phpMyAdmin
```

> English version: [README.en.md](README.en.md)

## 问题是什么

`class/acme_v2.py` 在把新证书覆盖到站点目录前，会先判断"这张新证书和站点现在用的那张是不是同一家 CA 签的"，判断依据是签发者的 **CN**：

```python
if to_cert_init['issuer'] != cert_init['issuer'] and to_cert_init['issuer'].find("Let's Encrypt") == -1:
    continue    # 静默跳过，一行日志都不写
```

Let's Encrypt 会轮换中间证书（现在是 `R10/R11/E5`，之后是 `YR1/YR2/...`）。代码拿到 `R11` 和 `YR2`，两个字符串里都不含 `Let's Encrypt`（那是在 `O=` 字段里，代码没读），于是判定"品牌不一致"→ 跳过部署。ACME 那边一切正常，所以面板显示续签成功，站点证书却停在旧的那张。

完整清单（带源码行号）见 [docs/ISSUES.md](docs/ISSUES.md)。

## 快速开始

```bash
# 1. 先看，不动任何东西
curl -fsSLO https://raw.githubusercontent.com/lengqie/bt77-acme-fix/main/bt77-acme-fix.sh
bash bt77-acme-fix.sh check

# 2. 修续期链路（会先备份、幂等、执行前二次确认）
bash bt77-acme-fix.sh fix

# 3. 可选加固，按需挑（每个参数的详细说明见 --help）
bash bt77-acme-fix.sh harden --panel-port 28488 --allow-ip "<你自己的公网IP>"

# 完整用法
bash bt77-acme-fix.sh --help
```

要求：root 权限、面板装在 `/www/server/panel`、`bash` 4+、`openssl`、`python3`。

> `--allow-ip` 用错会把自己关在门外（IP 写错或变成动态 IP）。救援：SSH 登录后 `rm -f /www/server/panel/data/limitip.conf && /etc/init.d/bt restart`。
> 家庭宽带/动态 IP 建议改用 `--basic-auth 用户名:密码`。

## `check` 会报什么

| 分区 | 检查内容 |
|---|---|
| 证书续期 | `acme_v2.py` 是否已打补丁、每日续签任务是否存在、面板的 python 里 `OpenSSL.crypto.PKCS12` 是否可用 |
| 证书订单 | 每条订单的域名、剩余天数、**没有 A 记录**的域名（http-01 永远验不过）、续期器会静默跳过的残缺订单 |
| 部署漂移 | 每个已下载的证书：`vhost/cert` 里实际提供给 nginx 的那张，和它是不是同一张 |
| 面板暴露面 | 面板端口、随机安全入口、IP 白名单、BasicAuth、ufw 里面板端口/888/被动 FTP 的放行、phpMyAdmin 是否存在、面板 HTTPS 是否开启 |

`check` 是纯只读的，发现问题也返回 0（它是报告，不是门禁）。

## `fix` 具体改什么

1. `class/acme_v2.py`
   - 增加 `_bt77_le_ca()`，用在签发者比对里：任何 Let's Encrypt 风格的中间证书 CN（`R11`、`YR2`……）都算同一家 CA；
   - 把可选的 pkcs12/IIS 导出包进 `try/except`：在 `OpenSSL.crypto.PKCS12` 缺失的机器上，这一步原来会**在部署之前**就抛异常，导致证书根本不落地；
   - 两处改动都带 `# [bt77-fix]` 标记，重复执行会跳过。
2. 续签任务：面板只在第一次使用 SSL 功能时才创建，所以新机器可能压根没有续期任务。缺失时补一条 `10 0 * * *` 执行 `acme_v2.py --renew=1`。
3. 部署同步（`--no-sync` 可跳过）：对 `vhost/letsencrypt` 里每个证书重跑面板自己的 `sub_all_cert()`，把已经卡在旧证书上的站点直接修好。
4. 重启面板，让常驻的 web 进程加载补丁。

备份在 `/root/bt77-acme-fix-<时间戳>/`（`acme_v2.py`、`crontab.bak`）。回滚：

```bash
cp /root/bt77-acme-fix-*/acme_v2.py /www/server/panel/class/acme_v2.py
/etc/init.d/bt restart
```

## `harden` 参数（全部可选，每个都会打印自己的回滚办法）

| 参数 | 作用 |
|---|---|
| `--panel-port N` | 写 `data/port.pl` 并重启面板；提醒你去云防火墙放行 N、关掉旧端口 |
| `--allow-ip "IP[,IP,-IP]"` | 写 `data/limitip.conf`（逗号分隔，区间用 `-`，不支持 CIDR），面板只对白名单来源应答 |
| `--basic-auth USER:PASS` | 按面板自己的 `md5(值 + "_bt.cn")` 规则写 `config/basic_auth.json` |
| `--close-pma` | 把 `/www/server/phpmyadmin` 移到备份目录，并删掉 ufw 的 `888/tcp` 放行 |
| `--yes` | 跳过交互确认 |

## 说明与限制

- 脚本不碰证书内容、不改站点配置；除了上面列出的参数，也不动防火墙。
- 全程本地执行，不连任何外部接口。
- 7.7.0 是 2021 年的版本，有一批永远不会修的已知问题。这个脚本只修两条具体的续期 bug 并降低暴露面，**不等于把面板变成安全版本**；能升级就升级。
- 比对基准是 [8838/btpanel-v7.7.0](https://github.com/8838/btpanel-v7.7.0) 里的 `install/src/LinuxPanel-7.7.0.zip`，另外在两台线上 7.7.0（Debian 12）验证过。其他发行版可能已经回填过代码：找不到原始锚点时 `fix` 会拒绝打补丁，`check` 依然能告诉你证书是否在漂移。

## 开发

```bash
bash -n bt77-acme-fix.sh          # 语法检查
shellcheck -S error bt77-acme-fix.sh
# 不 root 的情况下对着一份解包的面板源码跑：
BT77_ALLOW_NON_ROOT=1 PANEL_DIR=/tmp/panel PANEL_PY=python3 bash bt77-acme-fix.sh check
```

## 许可

MIT
