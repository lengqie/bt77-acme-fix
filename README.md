# bt77-acme-fix

Audit and repair script for **BT-Panel (Baota) 7.7.0** — the build many people keep because later
versions push account binding and forced upgrades.

A stock 7.7.0 install has a certificate-renewal defect that only shows up months later:
**Let's Encrypt renewals succeed, the new certificate is downloaded, and nginx keeps serving the
expired one.** This script finds that state, patches the two code paths responsible, restores the
missing deployment step, and reports the other traps of a fresh install.

```
check    read-only report, safe on production
fix      patch acme_v2.py, ensure the renewal cron, re-deploy drifted certificates
harden   opt-in: panel port, IP whitelist, BasicAuth, phpMyAdmin
```

## The problem

`class/acme_v2.py` deploys a renewed certificate by comparing it with the one currently used by the
site. The comparison includes the issuer **CN**:

```python
if to_cert_init['issuer'] != cert_init['issuer'] and to_cert_init['issuer'].find("Let's Encrypt") == -1:
    continue    # silently skip, not even a log line
```

Let's Encrypt rotates its intermediate CA (today `R10/R11/E5` become `YR1/YR2/...`). The comparison
sees `R11` vs `YR2`, neither contains the literal string `Let's Encrypt`, concludes "different CA",
and skips the copy. ACME still reports success, so the panel log says `续签成功` while the site keeps
an expired certificate until it is applied by hand.

See [docs/ISSUES.md](docs/ISSUES.md) for the full list with source references.

## Quick start

```bash
# 1. look before touching anything
curl -fsSLO https://raw.githubusercontent.com/lengqie/bt77-acme-fix/main/bt77-acme-fix.sh
bash bt77-acme-fix.sh check

# 2. patch the renewal path (backs everything up, idempotent, asks for confirmation)
bash bt77-acme-fix.sh fix

# 3. optional hardening, pick what you need
bash bt77-acme-fix.sh harden --panel-port 28488 --allow-ip 203.0.113.7
```

Requirements: root, BT-Panel 7.7.0 at `/www/server/panel`, `bash` 4+, `openssl`, `python3`.

## What `check` reports

| Section | Checks |
|---|---|
| certificate renewal | is `acme_v2.py` patched, does the daily renewal cron exist, does the panel python have a working `OpenSSL.crypto.PKCS12` |
| certificate orders | every order's domains, days left, domains with no A record (they can never validate over http-01), incomplete orders the renewer skips |
| deployment drift | for each downloaded certificate: is the copy served from `vhost/cert` actually the same one |
| panel exposure | panel port, random admin path, IP whitelist, BasicAuth, ufw rules for the panel port / 888 / passive FTP, phpMyAdmin presence, panel HTTPS |

Exit code is `0` even when it finds problems: it is a report, not a gate.

## What `fix` changes

1. `class/acme_v2.py`
   - adds `_bt77_le_ca()` and uses it in the issuer comparison, so any Let's Encrypt style
     intermediate CN (`R11`, `YR2`, ...) counts as the same CA family;
   - wraps the optional pkcs12/IIS export in `try/except`: on hosts where `OpenSSL.crypto.PKCS12`
     is missing, that export used to abort `save_cert()` **before** the site deployment;
   - both edits are marked `# [bt77-fix]` and skipped if already applied.
2. Renewal cron: the panel only creates it after you open the SSL page once, so a fresh install can
   have no renewal job at all. Adds `10 0 * * *` running `acme_v2.py --renew=1` if missing.
3. Deployment sync (`--no-sync` to skip): re-runs the panel's own `sub_all_cert()` for every
   certificate in `vhost/letsencrypt`, which repairs sites that are already stuck on an old copy.
4. Restarts the panel so the long-running web process picks up the patch.

Backups land in `/root/bt77-acme-fix-<timestamp>/` (`acme_v2.py`, `crontab.bak`).
Rollback:

```bash
cp /root/bt77-acme-fix-*/acme_v2.py /www/server/panel/class/acme_v2.py
/etc/init.d/bt restart
```

## Hardening flags (all opt-in, each prints its own rollback)

| Flag | Effect |
|---|---|
| `--panel-port N` | writes `data/port.pl`, restarts the panel; reminds you to open N and close the old port in the cloud firewall |
| `--allow-ip "IP[,IP,-IP]"` | writes `data/limitip.conf` (comma separated, ranges with `-`), panel only answers whitelisted sources |
| `--basic-auth USER:PASS` | writes `config/basic_auth.json` in the panel's own `md5(value + "_bt.cn")` format |
| `--close-pma` | moves `/www/server/phpmyadmin` into the backup directory and drops the `888/tcp` ufw rule |
| `--yes` | skip the interactive confirmation |

## Notes and limits

- The script does not modify certificates, site configs or firewall beyond the flags above.
- It never phones home; everything runs locally.
- 7.7.0 is a 2021 build with known unfixed issues. This script removes two specific renewal bugs and
  reduces exposure; it does not make the panel current. If you can upgrade, upgrade.
- Tested against the source archive in [8838/btpanel-v7.7.0](https://github.com/8838/btpanel-v7.7.0)
  (`install/src/LinuxPanel-7.7.0.zip`) and on two live 7.7.0 hosts (Debian 12). Other builds may
  have backported code: `fix` refuses to patch if it cannot find the exact stock anchors, and
  `check` will still tell you whether certificates are drifting.

## Development

```bash
bash -n bt77-acme-fix.sh          # syntax
shellcheck -S error bt77-acme-fix.sh
# run against an extracted panel tree without root:
BT77_ALLOW_NON_ROOT=1 PANEL_DIR=/tmp/panel PANEL_PY=python3 bash bt77-acme-fix.sh check
```

## License

MIT
