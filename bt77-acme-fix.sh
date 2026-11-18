#!/usr/bin/env bash
#
# bt77-acme-fix.sh
# Post-install fixes and audit for BT-Panel (Baota) 7.7.0.
#
# The 7.7.0 build silently fails to deploy renewed Let's Encrypt certificates
# once Let's Encrypt rotates its intermediate CA. This script patches that,
# reports the other traps of a fresh 7.7.0 install, and applies opt-in
# hardening.
#
# Usage:
#   bash bt77-acme-fix.sh check
#   bash bt77-acme-fix.sh fix [--no-sync] [--yes]
#   bash bt77-acme-fix.sh harden [--panel-port N] [--allow-ip LIST]
#                                   [--basic-auth USER:PASS] [--close-pma] [--yes]
#
# Env overrides (mainly for testing):
#   PANEL_DIR   default /www/server/panel
#   PANEL_PY    default $PANEL_DIR/pyenv/bin/python
#   BACKUP_DIR  default /root/bt77-acme-fix-<timestamp>
#
set -euo pipefail

VERSION="0.2.0"
PANEL_DIR="${PANEL_DIR:-/www/server/panel}"
PANEL_PY="${PANEL_PY:-$PANEL_DIR/pyenv/bin/python}"
ACME="$PANEL_DIR/class/acme_v2.py"
LE_CONF="$PANEL_DIR/config/letsencrypt.json"
CERT_DIR="$PANEL_DIR/vhost/cert"
LE_DIR="$PANEL_DIR/vhost/letsencrypt"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_DIR:-/root/bt77-acme-fix-$TS}"

if [ -t 1 ]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[36m'; C_0=$'\033[0m'
else
    C_R=''; C_G=''; C_Y=''; C_B=''; C_0=''
fi

log()  { printf '%s\n' "$*"; }
info() { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_Y" "$C_0" "$*"; }
fail() { printf '%s[FAIL]%s %s\n' "$C_R" "$C_0" "$*"; }
die()  { fail "$*"; exit 1; }

usage() {
    cat <<'EOF'
bt77-acme-fix.sh <子命令> [选项]

宝塔面板 7.7.0 安装后体检与修复。

子命令
  check                只读体检，不改任何东西
  fix                  打补丁 + 补续签任务 + 重新部署漂移证书 + 重启面板
  harden              加固，至少给一个选项（见下）

fix 的选项
  --no-sync            跳过“把已漂移的证书重新部署”这一步
  --yes, -y            跳过交互确认

harden 的选项（可组合，每个动作都会打印自己的回滚命令）
  --panel-port N       把面板端口改成 N（写 data/port.pl 并重启面板）
                       改完必须去云安全组/防火墙放行 N、关掉旧端口
  --allow-ip LIST      面板只对白名单来源应答，写 data/limitip.conf
                       LIST 逗号分隔，支持区间，例如：
                         --allow-ip "1.2.3.4,5.6.7.8,10.0.0.1-10.0.0.9"
                       注意：README 里的 203.0.113.7 是文档保留地址，必须换成你自己的 IP
                       家庭宽带/动态 IP 不建议用此项，IP 一变就把自己关在门外
  --basic-auth U:P     开启面板 BasicAuth（面板自己的 md5(值+"_bt.cn") 规则）
  --close-pma          把 phpMyAdmin 目录移到备份目录，并关闭 ufw 的 888/tcp
  --yes, -y            跳过交互确认

示例
  bash bt77-acme-fix.sh check
  bash bt77-acme-fix.sh fix
  bash bt77-acme-fix.sh harden --panel-port 28488
  bash bt77-acme-fix.sh harden --allow-ip "1.2.3.4,10.0.0.1-10.0.0.254" --basic-auth admin:密码
  bash bt77-acme-fix.sh harden --close-pma --yes

把自己锁在门外时
  rm -f /www/server/panel/data/limitip.conf      # 撤销 IP 白名单
  echo 8888 > /www/server/panel/data/port.pl     # 端口改回去
  /etc/init.d/bt restart

环境变量（调试用）
  PANEL_DIR   面板目录，默认 /www/server/panel
  PANEL_PY    面板 python，默认 $PANEL_DIR/pyenv/bin/python
  BACKUP_DIR  备份目录，默认 /root/bt77-acme-fix-<时间戳>
  BT77_ALLOW_NON_ROOT=1   允许非 root 运行（仅测试用）
EOF
    exit 0
}

need_root() {
    [ "$(id -u)" -eq 0 ] || [ "${BT77_ALLOW_NON_ROOT:-0}" = "1" ] || die "must run as root"
}

need_panel() {
    [ -f "$ACME" ] || die "BT-Panel not found at $PANEL_DIR (set PANEL_DIR)"
    if [ ! -x "$PANEL_PY" ]; then
        if command -v python3 >/dev/null 2>&1; then
            PANEL_PY="$(command -v python3)"
            warn "panel python not found, falling back to $PANEL_PY"
        else
            die "no python available"
        fi
    fi
}

panel_port() {
    if [ -f "$PANEL_DIR/data/port.pl" ]; then
        tr -d '[:space:]' < "$PANEL_DIR/data/port.pl"
    else
        printf '8888'
    fi
}

panel_admin_path() {
    if [ -f "$PANEL_DIR/data/admin_path.pl" ]; then
        tr -d '[:space:]' < "$PANEL_DIR/data/admin_path.pl"
    else
        printf '(none)'
    fi
}

panel_version() {
    sed -n "s/.*g\.version = '\([^']*\)'.*/\1/p" "$PANEL_DIR/class/common.py" 2>/dev/null | head -1
}

restart_panel() {
    if [ -x /etc/init.d/bt ]; then
        /etc/init.d/bt restart >/dev/null 2>&1 || warn "panel restart failed, run: /etc/init.d/bt restart"
        ok "panel restarted"
    elif command -v bt >/dev/null 2>&1; then
        bt restart >/dev/null 2>&1 || warn "panel restart failed, run: bt restart"
        ok "panel restarted"
    else
        warn "no init script found, restart BT-Panel manually so the patch is loaded"
    fi
}

# ---------------------------------------------------------------------------
# audit
# ---------------------------------------------------------------------------

check_acme_patch() {
    local n
    n="$(grep -c '# \[bt77-fix\]' "$ACME" 2>/dev/null || true)"
    if [ "${n:-0}" -ge 1 ]; then
        ok "acme_v2.py patched ($n markers)"
    else
        fail "acme_v2.py unpatched: renewed certs are never copied to vhost/cert"
        log "        fix with: bash $0 fix"
    fi
}

check_cron() {
    if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q 'acme_v2.py --renew'; then
        ok "renewal cron present: $(crontab -l 2>/dev/null | grep 'acme_v2.py --renew' | head -1)"
    else
        fail "no acme_v2.py --renew cron job: automatic renewal never runs"
        log "        the panel only creates it after you open the SSL page once"
        log "        fix with: bash $0 fix"
    fi
}

check_pyopenssl() {
    local out
    out="$("$PANEL_PY" -c 'import OpenSSL; print(OpenSSL.__version__, hasattr(OpenSSL.crypto, "PKCS12"))' 2>/dev/null || true)"
    case "$out" in
        *" True") ok "pyOpenSSL $out (PKCS12 available)" ;;
        *" False") warn "pyOpenSSL $out (no PKCS12): pkcs12 export will fail, patch keeps it non-fatal" ;;
        *) warn "cannot import OpenSSL with $PANEL_PY" ;;
    esac
}

check_orders() {
    [ -f "$LE_CONF" ] || { warn "no $LE_CONF yet (no certificate requested so far)"; return 0; }
    "$PANEL_PY" - "$LE_CONF" <<'PY'
import json, os, socket, sys, time

conf = json.load(open(sys.argv[1]))
orders = conf.get("orders") or {}
if not orders:
    print("[WARN] no certificate orders")
    raise SystemExit(0)

now = int(time.time())
dead = []
for idx, o in orders.items():
    doms = o.get("domains") or []
    has_path = bool(o.get("save_path"))
    ct = o.get("cert_timeout")
    missing = []
    for d in doms:
        d = d.lstrip("*.")
        try:
            socket.getaddrinfo(d, None, socket.AF_INET)
        except Exception:
            missing.append(d)
    left = "%.0f days" % ((ct - now) / 86400) if ct else "no cert"
    flag = ""
    if missing:
        flag = "  <-- no A record: %s" % ",".join(missing)
        dead.append((doms, missing))
    if not has_path:
        flag += "  <-- incomplete order, skipped by the renewer"
    print("[INFO] %-45s %-12s%s" % (",".join(doms), left, flag))

if dead:
    print("")
    print("[FAIL] %d order(s) can never validate over http-01." % len(dead))
    print("       Every daily retry burns Let's Encrypt's failed-validation quota")
    print("       (5 per hour per account) and can block renewals of healthy certs.")
    print("       Fix: add the missing A records, or delete the order in the panel,")
    print("       or switch those certificates to DNS-01.")
PY
}

check_drift() {
    [ -d "$LE_DIR" ] || { warn "no $LE_DIR yet"; return 0; }
    if ! compgen -G "$LE_DIR/*/fullchain.pem" >/dev/null; then
        info "  no downloaded certificates yet"
        return 0
    fi
    local found=0 f d a b
    for f in "$LE_DIR"/*/fullchain.pem; do
        [ -f "$f" ] || continue
        d="$(basename "$(dirname "$f")")"
        a="$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2)"
        b=""
        [ -f "$CERT_DIR/$d/fullchain.pem" ] && b="$(openssl x509 -in "$CERT_DIR/$d/fullchain.pem" -noout -enddate 2>/dev/null | cut -d= -f2)"
        if [ -z "$b" ]; then
            info "  $d: downloaded only (no site copy)"
        elif [ "$a" != "$b" ]; then
            found=1
            fail "  $d: downloaded $a / served $b  <-- stale certificate served by nginx"
        else
            info "  $d: $a (in sync)"
        fi
    done
    [ "$found" -eq 0 ] || log "        fix with: bash $0 fix   (re-runs the panel's own deploy routine)"
}

check_exposure() {
    local port; port="$(panel_port)"
    info "panel: port $port, path $(panel_admin_path), version $(panel_version)"
    if [ -s "$PANEL_DIR/data/limitip.conf" ]; then
        ok "IP whitelist: $(tr -d '\n' < "$PANEL_DIR/data/limitip.conf")"
    else
        warn "no IP whitelist (data/limitip.conf empty): panel port is open to the internet"
    fi
    if [ -f "$PANEL_DIR/config/basic_auth.json" ]; then
        ok "BasicAuth configured"
    else
        warn "BasicAuth off: only the random admin path protects the login page"
    fi
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -q "^Status: active"; then
            for p in "$port" 888 39000:40000; do
                if ufw status 2>/dev/null | grep -qE "(^| )$p(/tcp)? +(ALLOW|allow)"; then
                    warn "ufw allows $p from any source"
                fi
            done
        else
            info "ufw installed but inactive"
        fi
    fi
    [ -d /www/server/phpmyadmin ] && warn "phpMyAdmin installed on port 888 (well-known attack surface)" || true
    [ -f "$PANEL_DIR/data/ssl.pl" ] || warn "panel HTTPS disabled: the admin password travels in cleartext"
}

cmd_check() {
    need_panel
    info "BT-Panel $PANEL_DIR  (script $VERSION)"
    echo
    info "certificate renewal"
    check_acme_patch
    check_cron
    check_pyopenssl
    echo
    info "certificate orders"
    check_orders
    echo
    info "deployment drift"
    check_drift
    echo
    info "panel exposure"
    check_exposure
    echo
    info "done. apply the renewal fixes with: bash $0 fix"
}

# ---------------------------------------------------------------------------
# fix: acme_v2.py patch + cron + deploy sync
# ---------------------------------------------------------------------------

patch_acme() {
    mkdir -p "$BACKUP_DIR"
    cp -a "$ACME" "$BACKUP_DIR/acme_v2.py"
    ok "backup: $BACKUP_DIR/acme_v2.py"
    "$PANEL_PY" - "$ACME" <<'PY'
import io, sys

path = sys.argv[1]
src = io.open(path, encoding='utf-8').read().replace('\r\n', '\n')
orig = src
done = []

HELPER = '''# [bt77-fix] Let's Encrypt rotates its intermediate CA (R11, R12, YR1, YR2 ...).
# The stock 7.7.0 code compares the raw issuer CN and silently skips deploying a
# renewed certificate when the two differ, so nginx keeps serving the expired one.
# Treat any Let's Encrypt style intermediate CN as the same CA family.
def _bt77_le_ca(cn):
    if not cn:
        return False
    if "Let's Encrypt" in cn:
        return True
    return re.match(r'^[A-Z]{1,3}[0-9]+$', cn) is not None


'''

if '_bt77_le_ca' not in src:
    anchor = 'class acme_v2:'
    if src.count(anchor) != 1:
        sys.exit('cannot locate class acme_v2, aborting')
    src = src.replace(anchor, HELPER + anchor, 1)
    done.append('helper _bt77_le_ca')

old_cond = (
    "                if to_cert_init['issuer'] != cert_init['issuer'] "
    "and to_cert_init['issuer'].find(\"Let's Encrypt\") == -1:\n"
)
new_cond = (
    "                if (to_cert_init['issuer'] != cert_init['issuer']\n"
    "                        and to_cert_init['issuer'].find(\"Let's Encrypt\") == -1\n"
    "                        and not (_bt77_le_ca(to_cert_init['issuer'])\n"
    "                                 and _bt77_le_ca(cert_init['issuer']))):\n"
)
if old_cond in src:
    src = src.replace(old_cond, new_cond, 1)
    done.append('issuer family comparison')
elif '_bt77_le_ca(to_cert_init' not in src:
    sys.exit("issuer check not found, this is not a stock 7.7.0 acme_v2.py")

old_pfx = '''            # 转为IIS证书
            pfx_buffer = self.dump_pkcs12(
                cert['private_key'], cert['cert'] + cert['root'], cert['root'], domain_name)
            public.writeFile(path + "/fullchain.pfx", pfx_buffer, 'wb+')
'''
new_pfx = '''            # [bt77-fix] IIS/pkcs12 export is optional. Never let it abort the
            # site certificate deployment that follows.
            try:
                pfx_buffer = self.dump_pkcs12(
                    cert['private_key'], cert['cert'] + cert['root'], cert['root'], domain_name)
                public.writeFile(path + "/fullchain.pfx", pfx_buffer, 'wb+')
            except Exception as _bt77_e:
                write_log("|-IIS/pkcs12 export skipped: {}".format(_bt77_e))
'''
if old_pfx in src:
    src = src.replace(old_pfx, new_pfx, 1)
    done.append('non-fatal pkcs12 export')
elif '# [bt77-fix] IIS/pkcs12' not in src:
    print('[WARN] pkcs12 block not found, skipped that hunk')

if src == orig:
    print('[ OK ] acme_v2.py already patched')
    raise SystemExit(0)

io.open(path, 'w', encoding='utf-8').write(src)
print('[ OK ] patched: ' + ', '.join(done))
PY
    "$PANEL_PY" -m py_compile "$ACME" || die "acme_v2.py failed to compile, restore $BACKUP_DIR/acme_v2.py"
    ok "acme_v2.py compiles"
}

ensure_cron() {
    if ! command -v crontab >/dev/null 2>&1; then
        warn "no crontab binary, skip"
        return 0
    fi
    if crontab -l 2>/dev/null | grep -q 'acme_v2.py --renew'; then
        ok "renewal cron already present"
        return 0
    fi
    crontab -l > "$BACKUP_DIR/crontab.bak" 2>/dev/null || true
    { crontab -l 2>/dev/null || true;
      echo '10 0 * * * /www/server/panel/pyenv/bin/python /www/server/panel/class/acme_v2.py --renew=1 >> /www/server/panel/logs/letsencrypt-cron.log 2>&1';
    } | crontab -
    ok "renewal cron added (daily 00:10), previous crontab: $BACKUP_DIR/crontab.bak"
}

sync_certs() {
    [ -d "$LE_DIR" ] || { warn "no downloaded certificates yet, skip sync"; return 0; }
    "$PANEL_PY" - "$PANEL_DIR" <<'PY'
import os, sys
panel = sys.argv[1]
sys.path.insert(0, os.path.join(panel, 'class'))
os.chdir(panel)
import acme_v2

client = acme_v2.acme_v2()
base = os.path.join(panel, 'vhost', 'letsencrypt')
for name in sorted(os.listdir(base)):
    d = os.path.join(base, name)
    cert, key = os.path.join(d, 'fullchain.pem'), os.path.join(d, 'privkey.pem')
    if not (os.path.isfile(cert) and os.path.isfile(key)):
        continue
    print('[INFO] deploy %s' % name)
    try:
        client.sub_all_cert(key, cert)
    except Exception as e:
        print('[WARN] %s: %s' % (name, e))
PY
    ok "deployment sync finished"
}

cmd_fix() {
    local sync=1 assume=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --no-sync) sync=0 ;;
            --yes|-y) assume=1 ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done
    need_root
    need_panel
    if [ "$assume" -eq 0 ]; then
        log "This will:"
        log "  1. back up and patch $ACME"
        log "  2. make sure a daily renewal cron exists"
        [ "$sync" -eq 1 ] && log "  3. re-run the panel's deploy routine for every downloaded certificate"
        log "  4. restart the panel so the web process loads the patch"
        printf 'Continue? [y/N] '
        read -r reply
        case "$reply" in y|Y|yes) ;; *) log "aborted"; exit 0 ;; esac
    fi
    patch_acme
    ensure_cron
    [ "$sync" -eq 1 ] && sync_certs
    restart_panel
    echo
    ok "done. backups in $BACKUP_DIR"
    log "next: bash $0 check"
}

# ---------------------------------------------------------------------------
# harden
# ---------------------------------------------------------------------------

harden_confirm() {
    local text="$1"
    if [ "$ASSUME" -eq 0 ]; then
        printf '%s [y/N] ' "$text"
        read -r reply
        case "$reply" in y|Y|yes) ;; *) log "skipped"; return 1 ;; esac
    fi
    return 0
}

harden_panel_port() {
    local new="$1" old
    case "$new" in ''|*[!0-9]*) die "--panel-port must be numeric" ;; esac
    [ "$new" -ge 1024 ] && [ "$new" -le 65535 ] || die "--panel-port must be 1024-65535"
    old="$(panel_port)"
    if [ "$old" = "$new" ]; then ok "panel port already $new"; return 0; fi
    harden_confirm "change panel port $old -> $new and restart the panel?" || return 0
    mkdir -p "$BACKUP_DIR"
    cp -a "$PANEL_DIR/data/port.pl" "$BACKUP_DIR/port.pl" 2>/dev/null || true
    printf '%s' "$new" > "$PANEL_DIR/data/port.pl"
    restart_panel
    ok "panel port: $new (rollback: echo $old > $PANEL_DIR/data/port.pl && /etc/init.d/bt restart)"
    warn "open $new/tcp in your cloud firewall and close $old/tcp"
}

harden_limit_ip() {
    local list="$1" old
    [ -n "$list" ] || die "--allow-ip needs a value, e.g. 1.2.3.4,5.6.7.8,10.0.0.1-10.0.0.9"
    harden_confirm "restrict panel access to: $list ?" || return 0
    mkdir -p "$BACKUP_DIR"
    [ -f "$PANEL_DIR/data/limitip.conf" ] && cp -a "$PANEL_DIR/data/limitip.conf" "$BACKUP_DIR/limitip.conf"
    printf '%s' "$list" > "$PANEL_DIR/data/limitip.conf"
    chmod 600 "$PANEL_DIR/data/limitip.conf"
    printf 'True' > "$PANEL_DIR/data/reload.pl"
    ok "IP whitelist written (needs a panel restart to take effect)"
    log "      rollback: rm -f $PANEL_DIR/data/limitip.conf && /etc/init.d/bt restart"
}

harden_basic_auth() {
    local pair="$1" user pass
    user="${pair%%:*}"; pass="${pair#*:}"
    [ -n "$user" ] && [ -n "$pass" ] && [ "$user" != "$pass" ] || die "--basic-auth needs USER:PASS"
    harden_confirm "enable BasicAuth for user '$user' ?" || return 0
    mkdir -p "$BACKUP_DIR"
    [ -f "$PANEL_DIR/config/basic_auth.json" ] && cp -a "$PANEL_DIR/config/basic_auth.json" "$BACKUP_DIR/basic_auth.json"
    local u p
    u="$(printf '%s_bt.cn' "$user" | md5sum | cut -d' ' -f1)"
    p="$(printf '%s_bt.cn' "$pass" | md5sum | cut -d' ' -f1)"
    printf '{"basic_user": "%s", "basic_pwd": "%s", "open": true}' "$u" "$p" > "$PANEL_DIR/config/basic_auth.json"
    chmod 600 "$PANEL_DIR/config/basic_auth.json"
    printf 'True' > "$PANEL_DIR/data/reload.pl"
    ok "BasicAuth enabled (user $user)"
    log "      rollback: rm -f $PANEL_DIR/config/basic_auth.json && /etc/init.d/bt restart"
}

harden_close_pma() {
    local moved=0
    if [ -d /www/server/phpmyadmin ]; then
        harden_confirm "move /www/server/phpmyadmin aside (phpMyAdmin on port 888)?" || return 0
        mkdir -p "$BACKUP_DIR"
        mv /www/server/phpmyadmin "$BACKUP_DIR/phpmyadmin.removed"
        ok "phpMyAdmin moved to $BACKUP_DIR/phpmyadmin.removed"
        moved=1
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        ufw delete allow 888/tcp >/dev/null 2>&1 && ok "ufw: 888/tcp closed" || true
    fi
    if [ "$moved" -eq 0 ]; then
        ok "phpMyAdmin not installed, nothing to close"
    fi
    log "      rollback: mv $BACKUP_DIR/phpmyadmin.removed /www/server/phpmyadmin"
}

cmd_harden() {
    ASSUME=0
    local act=0 arg
    [ $# -gt 0 ] || die "harden needs at least one option, see --help"
    for arg in "$@"; do
        case "$arg" in --yes|-y) ASSUME=1 ;; esac
    done
    while [ $# -gt 0 ]; do
        case "$1" in
            --panel-port) shift; harden_panel_port "${1:-}"; act=1 ;;
            --allow-ip)   shift; harden_limit_ip "${1:-}";  act=1 ;;
            --basic-auth) shift; harden_basic_auth "${1:-}"; act=1 ;;
            --close-pma)  harden_close_pma; act=1 ;;
            --yes|-y)     ;;
            *) die "unknown option: $1 (bash $0 --help for usage)" ;;
        esac
        shift
    done
    [ "$act" -eq 1 ] || die "nothing to do"
    echo
    ok "hardening finished. verify with: bash $0 check"
}

# ---------------------------------------------------------------------------

ASSUME=0
cmd="${1:-check}"
[ $# -gt 0 ] && shift
case "$cmd" in
    check)             cmd_check "$@" ;;
    fix)               cmd_fix "$@" ;;
    harden)            cmd_harden "$@" ;;
    -h|--help|help)    usage ;;
    *)                 usage ;;
esac
