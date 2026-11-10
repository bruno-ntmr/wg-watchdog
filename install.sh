#!/bin/sh
# Installs the adjacent watchdog. No downloads, eval, or package installation.
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}
export PATH
LC_ALL=C
export LC_ALL
umask 077
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SOURCE=$HERE/wg-watchdog.sh
TIMEOUT=5
DRY=0
CRON=1
REMOVE=0
BIN=''
CONF=''
PLATFORM=linux
if [ -f /conf/config.xml ] && command -v configctl >/dev/null 2>&1; then
    PLATFORM=opnsense
elif [ -f /etc/openwrt_release ]; then PLATFORM=openwrt; fi
while [ "$#" -gt 0 ]; do
    case $1 in
        --timeout|--bin|--config)
            [ "$#" -ge 2 ] || exit 2
            case $1 in --timeout) TIMEOUT=$2 ;; --bin) BIN=$2 ;; --config) CONF=$2 ;; esac
            shift ;;
        --dry-run) DRY=1 ;;
        --no-cron) CRON=0 ;;
        --uninstall) REMOVE=1 ;;
        -h|--help)
            echo 'Usage: install.sh [--timeout MINUTES] [--dry-run] [--no-cron]'
            echo '                  [--bin /absolute/path] [--config /absolute/path]'
            echo '       install.sh --uninstall [--dry-run] [--bin PATH] [--config PATH]'
            echo 'Existing interface rows are preserved; new interfaces are appended.'
            echo 'Uninstall removes the job and executable, but preserves the config.'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
case $TIMEOUT in ''|*[!0-9]*) echo 'Invalid timeout' >&2; exit 2 ;; esac
[ "$TIMEOUT" -gt 0 ] && [ "$TIMEOUT" -le 525600 ] || exit 2
if [ -z "$BIN" ]; then
    case $PLATFORM in openwrt) BIN=/usr/sbin/wg-watchdog.sh ;; *) BIN=/usr/local/sbin/wg-watchdog.sh ;; esac
fi
if [ -z "$CONF" ]; then
    case $PLATFORM in opnsense) CONF=/usr/local/etc/wg-watchdog.conf ;; *) CONF=/etc/wg-watchdog.conf ;; esac
fi
for path in "$BIN" "$CONF"; do
    case $path in /*) ;; *) echo 'Paths must be absolute' >&2; exit 2 ;; esac
    case $path in *[!a-zA-Z0-9_./-]*) echo 'Paths must contain only letters, digits, / . _ -' >&2; exit 2 ;; esac
    [ ! -L "$path" ] || { echo "Refusing symlink: $path" >&2; exit 2; }
done
[ "$BIN" != "$CONF" ] || exit 2
[ "$(id -u)" = 0 ] || { echo 'Run as root; discovery needs access to VPN interfaces.' >&2; exit 2; }

tmp=$(mktemp -d /tmp/wg-watchdog-install.XXXXXX)
trap 'rm -rf "$tmp"' 0
trap 'exit 1' 1 2 15
ACTION=/usr/local/opnsense/service/conf/actions.d/actions_wgwatchdog.conf
echo "Platform: $PLATFORM; executable: $BIN; config: $CONF"

# Native MVC model writes config.xml with OPNsense validation and backup.
# A stable origin identifies OUR job; unrelated cron entries are untouched.
opn_cron() {
    php -r '
    require_once("script/load_phalcon.php");
    $m=new \OPNsense\Cron\Cron(); $ids=[]; $existing=null;
    foreach($m->jobs->job->iterateItems() as $id=>$n) {
        if((string)$n->origin==="wgwatchdog") { $ids[]=$id; if($existing===null)$existing=$n; }
    }
    if($argv[1]==="remove") {
        foreach($ids as $id) $m->jobs->job->del($id);
    } else {
        $n=$existing ?? $m->jobs->job->Add();
        foreach(array_slice($ids,1) as $id) $m->jobs->job->del($id);
        foreach(["origin"=>"wgwatchdog","enabled"=>"1","minutes"=>"*","hours"=>"*",
            "days"=>"*","months"=>"*","weekdays"=>"*","who"=>"root",
            "command"=>"wgwatchdog check","parameters"=>"",
            "description"=>"WG/AWG handshake watchdog"] as $key=>$value) $n->$key->setValue($value);
    }
    $m->serializeToConfig();
    \OPNsense\Core\Config::getInstance()->save("WG/AWG watchdog cron updated");
    ' "$1"
    configctl cron restart
}

# Finish our own interrupted restart before replacing/removing its executable.
# An intentionally disabled instance without a recovery record is untouched.
if [ "$DRY" = 0 ] && [ "$PLATFORM" = opnsense ] && [ -r "$BIN" ] &&
    grep -q -- '--recover-only' "$BIN"; then
    sh "$BIN" --recover-only
fi

if [ "$CRON" = 1 ] && [ "$PLATFORM" != opnsense ]; then
    command -v crontab >/dev/null 2>&1 || { echo 'Install cron/crontab first, or use --no-cron.' >&2; exit 1; }
    crontab -l > "$tmp/crontab.old" 2> "$tmp/crontab.error" || {
        # A missing root crontab is normal; other failures must not erase jobs.
        if [ -s "$tmp/crontab.old" ] || ! grep -Eqi 'no crontab|not found|No such file' "$tmp/crontab.error"; then
            cat "$tmp/crontab.error" >&2; exit 1
        fi
        : > "$tmp/crontab.old"
    }
    sed '/# wg-watchdog managed$/d' "$tmp/crontab.old" > "$tmp/crontab.new"
fi

if [ "$REMOVE" = 1 ]; then
    if [ "$DRY" = 1 ]; then echo "Would remove managed cron job and $BIN; preserve $CONF"; exit 0; fi
    if [ "$CRON" = 1 ]; then
        if [ "$PLATFORM" = opnsense ]; then
            opn_cron remove
            rm -f "$ACTION"
            service configd restart >/dev/null
        else crontab "$tmp/crontab.new"; fi
    fi
    rm -f "$BIN"
    echo "Uninstalled; config preserved at $CONF"
    exit 0
fi

[ -r "$SOURCE" ] || { echo "Missing adjacent $SOURCE" >&2; exit 1; }
sh -n "$SOURCE"
sh "$SOURCE" --discover --timeout "$TIMEOUT" > "$tmp/discovered"
if [ -f "$CONF" ]; then
    # Preserve all existing values/comments, append only previously unseen names.
    awk 'FILENAME==ARGV[1] {print; sub(/#.*/, ""); if(NF)seen[$1]=1; next}
         !seen[$1] {print}' "$CONF" "$tmp/discovered" > "$tmp/config"
else
    printf '# Generated by wg-watchdog installer; edit timeouts/backends as needed.\n# interface timeout_minutes backend target tool\n' > "$tmp/config"
    cat "$tmp/discovered" >> "$tmp/config"
fi
echo 'Discovered supported interfaces:'
cat "$tmp/discovered"
# Validate the complete merged config without running a restart or writing state.
sh "$SOURCE" -c "$tmp/config" --dry-run
if [ "$CRON" = 1 ] && [ "$PLATFORM" != opnsense ]; then
    printf '* * * * * %s -c %s # wg-watchdog managed\n' "$BIN" "$CONF" >> "$tmp/crontab.new"
fi
if [ "$DRY" = 1 ]; then
    echo 'Resulting config:'; cat "$tmp/config"
    [ "$CRON" = 0 ] || echo 'Would install one managed cron job: every minute.'
    exit 0
fi

mkdir -p "${BIN%/*}" "${CONF%/*}"
stamp=$(date +%Y%m%d%H%M%S)
if [ -f "$CONF" ]; then
    cp -p "$CONF" "$CONF.bak.$stamp"
fi
# Rename within the destination filesystem: readers see a complete file.
cp "$SOURCE" "$BIN.new.$$"
chmod 755 "$BIN.new.$$"
mv -f "$BIN.new.$$" "$BIN"
cp "$tmp/config" "$CONF.new.$$"
chmod 600 "$CONF.new.$$"
mv -f "$CONF.new.$$" "$CONF"

if [ "$CRON" = 1 ]; then
    case $PLATFORM in
        opnsense)
            cat > "$tmp/action" <<EOF
[check]
command:$BIN
parameters:-c $CONF
type:script
message:check WireGuard and AmneziaWG handshakes
description:Check WireGuard and AmneziaWG handshakes
EOF
            cp "$tmp/action" "$ACTION"
            chmod 644 "$ACTION"
            service configd restart >/dev/null
            opn_cron install ;;
        openwrt)
            crontab "$tmp/crontab.new"
            /etc/init.d/cron enable
            /etc/init.d/cron start ;;
        linux)
            crontab "$tmp/crontab.new"
            if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
                cron_service=''
                for unit in cron.service crond.service; do
                    if [ "$(systemctl show -p LoadState --value "$unit" 2>/dev/null)" = loaded ]; then cron_service=$unit; break; fi
                done
                [ -n "$cron_service" ] || { echo 'Cron installed but no cron/crond systemd unit; enable your cron daemon.' >&2; exit 1; }
                systemctl enable --now "$cron_service"
            elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
                if [ -x /etc/init.d/crond ]; then cron_service=crond; else cron_service=cron; fi
                rc-update add "$cron_service" default
                rc-service "$cron_service" start
            elif [ -x /etc/init.d/cron ] || [ -x /etc/init.d/crond ]; then
                if [ -x /etc/init.d/cron ]; then cron_service=cron; else cron_service=crond; fi
                "/etc/init.d/$cron_service" start
                if command -v update-rc.d >/dev/null 2>&1; then update-rc.d "$cron_service" defaults; fi
            else
                echo 'Cron entry installed; verify that the cron daemon is running.' >&2
            fi ;;
    esac
fi
echo 'Installed. Existing interface settings preserved; no immediate restart was requested.'
