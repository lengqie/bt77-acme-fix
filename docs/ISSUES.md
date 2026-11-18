# Issues in BT-Panel 7.7.0 that show up after install

References are to the stock 7.7.0 source archive
[`8838/btpanel-v7.7.0`](https://github.com/8838/btpanel-v7.7.0)
(`install/src/LinuxPanel-7.7.0.zip`, `panel/` prefix omitted).

| # | Issue | Where | Symptom | Script |
|---|---|---|---|---|
| 1 | Renewed certificate never deployed after a Let's Encrypt intermediate CA rotation | `class/acme_v2.py:780-782` | log says `续签成功`, nginx serves the expired certificate | `fix` |
| 2 | Optional pkcs12 export can abort certificate deployment | `class/acme_v2.py:736-739` | `AttributeError: module 'OpenSSL.crypto' has no attribute 'PKCS12'` in `logs/letsencrypt.log`, nothing written to `vhost/cert` | `fix` |
| 3 | Renewal cron is only created when the SSL feature is used for the first time | `class/acme_v2.py:1386` (`set_crond`) | a panel with certificates but no cron job: nothing renews, ever | `fix` |
| 4 | Orders whose domains cannot validate keep retrying every day | `class/acme_v2.py:1447+` (renew loop) | Let's Encrypt returns "too many failed authorizations"; healthy certificates fail too because the quota is account-wide | `check` (reports), manual removal |
| 5 | Fresh install opens 20/21/22/80/888/panel-port/39000-40000 to the world | `install/install_panel.sh:575-595` | panel and phpMyAdmin reachable from any IP | `harden --allow-ip`, `--close-pma` |
| 6 | Panel runs plain HTTP, no IP whitelist, BasicAuth off | `class/config.py:335-382` | admin password sent in cleartext, login page protected only by the random `admin_path` | `harden` |
| 7 | phpMyAdmin served on port 888 | `class/panelPlugin.py:1623` | long-standing attack surface | `harden --close-pma` |

## 1. Certificate deployment is skipped after an intermediate CA rotation

```python
# sub_all_cert(): replace certificates that overlap with the freshly issued one
# 判断证书品牌是否一致
if to_cert_init['issuer'] != cert_init['issuer'] and to_cert_init['issuer'].find("Let's Encrypt") == -1:
    continue
```

`issuer` here is only the certificate CN, not the full distinguished name. Stock certificates were
issued by `R11`; the new one by `YR2`. They differ, and neither CN contains the string
`Let's Encrypt` (that lives in the `O=` field, which is never read), so the loop `continue`s.
No log line is written — the renewal looks successful from the panel.

Failure is intermittent by nature: everything works until Let's Encrypt rotates the intermediate,
then every site stops receiving renewals at once.

The script treats any `^[A-Z]{1,3}\d+$` CN as a Let's Encrypt intermediate
(`R3`, `R10`, `R11`, `E5`, `YR1`, `YR2`, ...) and requires it on **both** sides, so a real
third-party certificate is still left untouched.

## 2. pkcs12 export gates the deployment

```python
# save_cert()
# 转为IIS证书
pfx_buffer = self.dump_pkcs12(
    cert['private_key'], cert['cert'] + cert['root'], cert['root'], domain_name)
public.writeFile(path + "/fullchain.pfx", pfx_buffer, 'wb+')
...
self.sub_all_cert(key_file, pem_file)   # never reached if the line above raises
```

`save_cert()` wraps everything in a bare `try/except` and only writes `public.get_error_info()` to
the panel log, so the failure is invisible unless you open `logs/letsencrypt.log`.

`pyOpenSSL` is pinned to `19.1.0` in `requirements.txt:65`, which does ship `PKCS12`; the observed
breakage is on hosts where a partial pyOpenSSL/cryptography upgrade left the panel runtime without
it (`OpenSSL.crypto.PKCS12` raises `AttributeError` from `cryptography.utils.__getattr__`).
Because the export is IIS-only and irrelevant to nginx, the script makes it non-fatal: a failed
export logs one line and deployment continues.

## 3. No renewal cron until the SSL page is opened

`set_crond()` adds the `续签Let's Encrypt证书` task to the panel database and the system crontab.
It is called from the certificate apply path, not from the installer. A panel that has never had a
certificate requested through the UI has no renewal job at all, and the same happens if the panel
database was restored without crontab entries.

`check` reports it and `fix` re-creates the missing line:

```
10 0 * * * /www/server/panel/pyenv/bin/python /www/server/panel/class/acme_v2.py --renew=1
```

## 4. Unvalidatable orders poison the whole account

Every order is retried daily. If a certificate covers a domain that does not resolve to this server
(a bare apex without an `A` record, a hostname behind Cloudflare with different routing, a
`www.` that was never created), http-01 fails forever. Let's Encrypt counts failed validations per
**account** — 5 per hour — and the panel has no backoff for that specific error, so a single dead
order can block renewals of every healthy certificate on the machine.

`check` resolves every domain in every order and lists the ones without an `A` record, plus
incomplete orders (no `save_path`) that the renewer silently skips.

Remedy: add the missing records, delete the order in the panel, or move that certificate to DNS-01.
The script does not delete orders for you.

## 5–7. Exposure after a fresh install

```
install/install_panel.sh:471   panelPort="8888"
install/install_panel.sh:587   ufw allow 888/tcp
install/install_panel.sh:588   ufw allow ${panelPort}/tcp
```

`ufw allow` without `from <ip>` means the whole internet. Combined with `class/config.py` defaults
(empty `data/limitip.conf`, no `config/basic_auth.json`) the login page is protected only by the
random 8-hex `admin_path`, served over plain HTTP, with phpMyAdmin next door on 888.

`harden` addresses this with explicit, reversible flags; see the README table.
