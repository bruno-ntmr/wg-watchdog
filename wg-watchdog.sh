#!/bin/sh
# POSIX sh; uses the platform's existing VPN/network management tools.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}
export PATH
LC_ALL=C
export LC_ALL
umask 077

CONFIG=/etc/wg-watchdog.conf
STATE=/var/run/wg-watchdog
DRY=0
VERBOSE=0
DISCOVER=0
RECOVER_ONLY=0
DEFAULT_TIMEOUT=5
while [ "$#" -gt 0 ]; do
    case $1 in
        -c|--config) [ "$#" -ge 2 ] || exit 2; CONFIG=$2; shift ;;
        --state-dir) [ "$#" -ge 2 ] || exit 2; STATE=$2; shift ;;
        --dry-run) DRY=1; VERBOSE=1 ;;
        -v|--verbose) VERBOSE=1 ;;
        --discover) DISCOVER=1 ;;
        --recover-only) RECOVER_ONLY=1 ;;
        --timeout) [ "$#" -ge 2 ] || exit 2; DEFAULT_TIMEOUT=$2; shift ;;
        -h|--help)
            echo 'Usage: wg-watchdog.sh [-c FILE] [--state-dir DIR] [--dry-run] [-v]'
            echo 'Config: interface timeout_minutes [backend [target [wg|awg|awg3]]]'
            echo 'Discovery: --discover [--timeout MINUTES] (prints config; no changes)'
            echo 'Recovery: --recover-only [--state-dir DIR] (restore interrupted OPNsense AWG toggle)'
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

log() {
    printf '%s\n' "wg-watchdog: $*" >&2
    [ "$DRY" = 1 ] || logger -t wg-watchdog "$*" 2>/dev/null || :
}
info() { [ "$VERBOSE" = 0 ] || log "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
token() { case $1 in ''|*[!a-zA-Z0-9_.:-]*|-*) return 1 ;; esac; }
number() { case $1 in ''|*[!0-9]*) return 1 ;; esac; }
uuid() {
    printf '%s\n' "$1" | awk -F- '
        NF==5 && $0 ~ /^[0-9a-f-]+$/ && length($1)==8 && length($2)==4 &&
        length($3)==4 && length($4)==4 && length($5)==12 {ok=1}
        END {exit !ok}'
}

# Only nonsecret identifiers leave PHP. PHP is part of OPNsense itself.
opn_disabled() {
    php -r '
    $x=@simplexml_load_file("/conf/config.xml"); if(!$x)exit(1);
    $q=$argv[1]; $dev=$q;
    foreach($x->interfaces->children() as $k=>$v)
        if($q===(string)$k || $q===(string)$v->descr)$dev=(string)$v->if;
    $matches=[];
    foreach([["wireguard","wg","server/servers/server"],
             ["amneziawg","awg","instance/instances/instance"]] as [$kind,$prefix,$path]) {
        $model=$x->OPNsense->$kind;
        foreach($model->xpath($path) as $n) {
            $d=$prefix.(string)$n->instance;
            if($dev===$d || $q===(string)$n->name)
                $matches[]=[$d,(string)$model->general->enabled!=="1" || (string)$n->enabled!=="1"];
        }
    }
    if(count($matches)!==1 || !$matches[0][1])exit(1);
    echo $matches[0][0],"\n";
    ' "$1" 2>/dev/null
}

opn_resolve() {
    php -r '
    $x=@simplexml_load_file("/conf/config.xml"); if (!$x) exit(1);
    $q=$argv[1]; $dev=$q;
    foreach ($x->interfaces->children() as $k=>$v) {
        if ($q===(string)$k || $q===(string)$v->descr) $dev=(string)$v->if;
    }
    $matches=[];
    if ((string)$x->OPNsense->wireguard->general->enabled==="1") {
        foreach ($x->OPNsense->wireguard->server->servers->server as $s) {
            $d="wg".(string)$s->instance;
            if ((string)$s->enabled==="1" && ($q===(string)$s->name || $dev===$d))
                $matches[]=$d." opnsense-wg ".(string)$s["uuid"];
        }
    }
    if ((string)$x->OPNsense->amneziawg->general->enabled==="1") {
        foreach ($x->OPNsense->amneziawg->instance->instances->instance as $s) {
            $d="awg".(string)$s->instance;
            if ((string)$s->enabled==="1" && ($q===(string)$s->name || $dev===$d))
                $matches[]=$d." opnsense-awg ".(string)$s["uuid"];
        }
    }
    if(count($matches)!==1) exit(1); echo $matches[0],"\n";
    ' "$1" 2>/dev/null
}

# Conservative userspace detection: a running procd AWG service must have a
# literal, single-interface amneziawg-go invocation in its executable wrapper.
# Variable-driven/custom wrappers can be selected explicitly in the config.
userspace_services() {
    procd_data=$(ubus call service list 2>/dev/null) || return 1
    for service_file in /etc/init.d/*; do
        [ -f "$service_file" ] || continue
        grep -q 'procd_set_param' "$service_file" || continue
        svc=${service_file##*/}
        token "$svc" || continue
        commands=$(printf '%s\n' "$procd_data" |
            jsonfilter -e "@[\"$svc\"].instances.*.command[*]" 2>/dev/null)
        instances=$(printf '%s\n' "$procd_data" |
            jsonfilter -e "@[\"$svc\"].instances.*.running" 2>/dev/null)
        [ "$instances" = true ] || continue
        matched=0
        for exe in $commands; do
            case $exe in /*) ;; *) continue ;; esac
            [ -f "$exe" ] || continue
            [ "$(dd if="$exe" bs=2 count=1 2>/dev/null)" = '#!' ] || continue
            if awk -v dev="$IFACE" '
                /^[ \t]*#/ {next}
                /amneziawg-go[ \t]/ {
                    for(i=1;i<=NF;i++) if($i ~ /(^|\/)amneziawg-go$/) {
                        j=i+1; if($j=="-f") j++;
                        d=$j; sub(/[;&].*$/, "", d);
                        count++; if(d==dev) found++;
                    }
                }
                END {exit !(count==1 && found==1)}' "$exe"; then matched=1; fi
        done
        [ "$matched" = 0 ] || printf '%s\n' "$svc"
    done
}

detect_backend() {
    if [ -f /etc/rc.conf ] && have configctl && [ -f /conf/config.xml ]; then
        mapping=$(opn_resolve "$NAME") || return 1
        set -- $mapping
        IFACE=$1; BACKEND=$2; TARGET=$3
        return 0
    fi
    if [ -f /etc/openwrt_release ] && have ubus && have jsonfilter; then
        # Resolve either a netifd logical name or its actual L3 device.
        matches=$(ubus call network.interface dump 2>/dev/null |
            jsonfilter -e "@.interface[@.interface=\"$NAME\"].interface" \
                       -e "@.interface[@.l3_device=\"$NAME\"].interface" 2>/dev/null | sort -u)
        set -- $matches
        [ "$#" = 1 ] || return 1
        logical=$1
        status=$(ubus call "network.interface.$logical" status 2>/dev/null) || return 1
        IFACE=$(printf '%s\n' "$status" | jsonfilter -e '@.l3_device')
        proto=$(printf '%s\n' "$status" | jsonfilter -e '@.proto')
        case $proto in
            wireguard|amneziawg|amneziawg2|amneziawg3)
                BACKEND=openwrt; TARGET=$logical; return 0 ;;
        esac
        services=$(userspace_services)
        set -- $services
        [ "$#" = 1 ] || return 1
        BACKEND=openwrt-service; TARGET=$1; return 0
    fi
    # Existing active managers take priority over standalone config files.
    if have nmcli; then
        connection=$(nmcli -g GENERAL.CON-UUID device show "$IFACE" 2>/dev/null)
        if uuid "$connection"; then BACKEND=networkmanager; TARGET=$connection; return 0; fi
    fi
    if have systemctl && [ -d /run/systemd/system ]; then
        for kind in wg awg; do
            unit=$kind-quick@$IFACE.service
            if systemctl is-active --quiet "$unit"; then
                BACKEND=systemd; TARGET=$unit; return 0
            fi
        done
    fi
    # Do not compete with networkd. Its down/up does not recreate a WG netdev.
    if have networkctl && networkctl status "$IFACE" --no-pager 2>/dev/null |
        grep -Eq 'Network File: /'; then return 1; fi
    configs=''
    count=0
    for config_file in /etc/wireguard/"$IFACE.conf" /etc/amnezia/amneziawg/"$IFACE.conf" /etc/amnezia/"$IFACE.conf"; do
        [ -r "$config_file" ] || continue
        count=$((count + 1)); configs=$config_file
    done
    [ "$count" = 1 ] || return 1
    if have wg && wg show "$IFACE" public-key >/dev/null 2>&1; then
        BACKEND=wg-quick
    elif have awg && awg show "$IFACE" public-key >/dev/null 2>&1; then
        BACKEND=awg-quick
    else return 1; fi
    have "$BACKEND" || return 1
    TARGET=$configs
}

validate_backend() {
    case $BACKEND in
        openwrt) have ubus && token "$TARGET" ;;
        openwrt-service) token "$TARGET" && [ -x "/etc/init.d/$TARGET" ] ;;
        opnsense-wg|opnsense-awg)
            have configctl && uuid "$TARGET" || return 1
            case $TARGET in ????????-????-4???-[89ab]???-????????????) ;; *) return 1 ;; esac
            [ "$(opn_resolve "$IFACE")" = "$IFACE $BACKEND $TARGET" ] || return 1
            if [ "$BACKEND" = opnsense-awg ]; then
                grep -q 'parameters: reconfigure %s' /usr/local/opnsense/service/conf/actions.d/actions_amneziawg.conf
            fi ;;
        systemd) have systemctl && token "$TARGET" ;;
        networkmanager) have nmcli && uuid "$TARGET" ;;
        wg-quick|awg-quick) have "$BACKEND" && [ -r "$TARGET" ] ;;
        *) return 1 ;;
    esac
}

# Use the same model/save path as the instance checkbox, without touching keys.
opn_awg_enabled() {
    php -r '
    require_once("script/load_phalcon.php");
    $m=new \OPNsense\AmneziaWG\Instance(); $node=null;
    foreach($m->instances->instance->iterateItems() as $id=>$n) {
        if($id===$argv[1]) $node=$n;
    }
    if($node===null || "awg".(string)$node->instance!==$argv[2]) exit(3);
    $current=(string)$node->enabled; $desired=$argv[3];
    if($desired==="0") {
        if($current!=="1" || (string)(new \OPNsense\AmneziaWG\General())->enabled!=="1") exit(3);
    } elseif($desired!=="1") exit(1);
    if($current===$desired) exit(0);
    $node->enabled->setValue($desired);
    $m->serializeToConfig();
    \OPNsense\Core\Config::getInstance()->save("WG/AWG watchdog: instance enabled=".$desired);
    ' "$1" "$2" "$3" >/dev/null 2>&1
}

opn_awg_apply() {
    # Checkbox API applies this UUID; the GUI Apply button then applies globally.
    # Global reconfigure keeps other enabled, running instances in place.
    php -r '$x=@simplexml_load_file("/conf/config.xml"); exit($x && (string)$x->OPNsense->amneziawg->general->enabled==="1" ? 0 : 1);' >/dev/null 2>&1 || return 1
    configctl amneziawg reconfigure "$1" >/dev/null 2>&1 || return 1
    configctl amneziawg reconfigure >/dev/null 2>&1
}

opn_pending_path() {
    if [ "$STATE" = /var/run/wg-watchdog ] && [ -f /conf/config.xml ]; then
        # enabled=0 is persistent: its recovery record must survive reboot too.
        printf '%s\n' /conf/wg-watchdog.pending
    else printf '%s\n' "$STATE/opnsense-awg.pending"; fi
}

recover_opn_awg() {
    pending_path=$(opn_pending_path)
    [ -f "$pending_path" ] || return 0
    pending_uuid=''; pending_iface=''; extra=''
    read -r pending_uuid pending_iface extra < "$pending_path" || :
    uuid "$pending_uuid" && token "$pending_iface" && [ -z "$extra" ] || {
        log 'invalid OPNsense AWG recovery record; manual recovery required'; return 1;
    }
    log "$pending_iface: restoring enabled instance after interrupted restart"
    opn_awg_enabled "$pending_uuid" "$pending_iface" 1 &&
        opn_awg_apply "$pending_uuid" &&
        ifconfig "$pending_iface" >/dev/null 2>&1 &&
        configctl filter reload >/dev/null 2>&1 || {
            log "$pending_iface: recovery FAILED; record retained for next invocation"; return 1;
        }
    rm -f "$pending_path"
}

restart_opn_awg() {
    # Record BEFORE disabling. EXIT/signal cleanup and the next cron invocation
    # can restore the original enabled=1 even after an uncatchable SIGKILL.
    pending_path=$(opn_pending_path)
    printf '%s %s\n' "$1" "$2" > "$pending_path.new.$$" || return 1
    mv -f "$pending_path.new.$$" "$pending_path" || return 1
    if opn_awg_enabled "$1" "$2" 0; then :; else
        enabled_status=$?
        # A concurrent admin disable/deletion must not be undone by recovery.
        [ "$enabled_status" != 3 ] || rm -f "$pending_path"
        return 1
    fi
    opn_awg_apply "$1" || return 1
    if ifconfig "$2" >/dev/null 2>&1; then
        log "$2: disabled Apply did not remove the interface"; return 1
    fi
    sleep 2
    opn_awg_enabled "$1" "$2" 1 && opn_awg_apply "$1" &&
        ifconfig "$2" >/dev/null 2>&1 &&
        configctl filter reload >/dev/null 2>&1 || return 1
    rm -f "$pending_path"
}

restart_interface() {
    # Do not copy tool output to logs: quick hooks may expose config secrets.
    case $BACKEND in
        openwrt)
            ubus call "network.interface.$TARGET" down >/dev/null 2>&1 || return 1
            ubus call "network.interface.$TARGET" up >/dev/null 2>&1 ;;
        openwrt-service) "/etc/init.d/$TARGET" restart >/dev/null 2>&1 ;;
        opnsense-wg) configctl wireguard restart "$TARGET" >/dev/null 2>&1 ;;
        opnsense-awg)
            restart_opn_awg "$TARGET" "$IFACE" ;;
        systemd) systemctl restart "$TARGET" >/dev/null 2>&1 ;;
        networkmanager)
            nmcli connection down uuid "$TARGET" >/dev/null 2>&1 || return 1
            nmcli connection up uuid "$TARGET" >/dev/null 2>&1 ;;
        wg-quick|awg-quick)
            "$BACKEND" down "$TARGET" >/dev/null 2>&1 || return 1
            "$BACKEND" up "$TARGET" >/dev/null 2>&1 ;;
    esac
}

handshake() {
    if [ "$TOOL" = auto ]; then
        case $IFACE in awg*|amn*) candidates='awg awg3 wg' ;; *) candidates='wg awg awg3' ;; esac
    else candidates=$TOOL; fi
    for candidate in $candidates; do
        have "$candidate" || continue
        data=$("$candidate" show "$IFACE" latest-handshakes 2>/dev/null) || continue
        latest=$(printf '%s\n' "$data" | awk '
            NF {if(NF!=2 || $2 !~ /^[0-9]+$/) bad=1; n++; if($2>m)m=$2}
            END {if(bad || !n) exit 1; printf "%.0f\n",m+0}') || continue
        TOOL=$candidate; return 0
    done
    return 1
}

interface_up() {
    link_state=''
    if have ip; then link_state=$(ip -o link show dev "$IFACE" 2>/dev/null) || link_state=''; fi
    if [ -z "$link_state" ] && have ifconfig; then
        link_state=$(ifconfig "$IFACE" 2>/dev/null) || return 2
    fi
    case $link_state in *\<*\>*) ;; *) return 2 ;; esac
    link_flags=${link_state#*<}; link_flags=${link_flags%%>*}
    case ,$link_flags, in *,UP,*) return 0 ;; *) return 1 ;; esac
}

check_interface() {
    NAME=$1; minutes=$2; BACKEND=${3:-auto}; TARGET=${4:--}; TOOL=${5:-auto}
    IFACE=$NAME
    token "$NAME" && number "$minutes" && [ "$minutes" -gt 0 ] &&
        [ "$minutes" -le 525600 ] || { log "invalid interface/timeout: $NAME"; return 1; }
    # Strip leading zeros before POSIX shell arithmetic (08 is not octal).
    minutes=$(printf '%s\n' "$minutes" | sed 's/^0*//')
    threshold=$((minutes * 60))
    case $TOOL in auto|wg|awg|awg3) ;; *) log "$NAME: invalid tool"; return 1 ;; esac
    if [ -f /conf/config.xml ] && have configctl; then
        if disabled_iface=$(opn_disabled "$NAME") && token "$disabled_iface"; then
            info "$NAME: instance or VPN globally disabled by administrator; skipping"
            [ "$DRY" = 1 ] || rm -f "$STATE/$disabled_iface.since"
            return 0
        fi
    fi
    if [ "$BACKEND" = auto ]; then
        detect_backend || { log "$NAME: cannot unambiguously detect owner; specify backend and target"; return 1; }
    fi
    token "$IFACE" || { log "$NAME: invalid resolved device"; return 1; }
    if [ "$TARGET" = - ]; then
        case $BACKEND in
            openwrt) TARGET=$IFACE ;;
            wg-quick) TARGET=/etc/wireguard/$IFACE.conf ;;
            awg-quick) TARGET=/etc/amnezia/amneziawg/$IFACE.conf ;;
        esac
    fi
    validate_backend || { log "$NAME: backend unavailable/invalid: $BACKEND $TARGET"; return 1; }
    if interface_up; then :; else
        link_status=$?
        if [ "$link_status" = 1 ]; then
            info "$NAME: interface administratively down; skipping"
            [ "$DRY" = 1 ] || rm -f "$STATE/$IFACE.since"
            return 0
        fi
        log "$NAME: cannot read administrative interface state; skipping"; return 1
    fi
    handshake || { log "$NAME ($IFACE): cannot read handshakes or no peers; skipping"; return 1; }
    now=$(date +%s)
    number "$now" || return 1
    age=$((now - latest))
    if [ "$age" -lt 0 ]; then log "$NAME: handshake is in the future; check system clock"; return 1; fi
    anchor=$now
    if [ -f "$STATE/$IFACE.since" ]; then
        read -r anchor < "$STATE/$IFACE.since" || :
        number "$anchor" || anchor=$now
        [ "$anchor" -le "$now" ] || anchor=$now
    elif [ "$DRY" = 0 ]; then
        printf '%s\n' "$anchor" > "$STATE/$IFACE.since" || return 1
    fi
    info "$NAME: device=$IFACE tool=$TOOL backend=$BACKEND target=$TARGET latest=$latest age=${age}s timeout=${threshold}s"
    [ "$latest" = 0 ] || [ "$age" -ge "$threshold" ] || return 0
    if [ $((now - anchor)) -lt "$threshold" ]; then
        info "$NAME: startup/restart grace period; waiting"
        return 0
    fi
    if [ "$DRY" = 1 ]; then log "$NAME: would restart $BACKEND $TARGET"; return 0; fi
    # Cooldown starts on every attempt, including a failed restart.
    printf '%s\n' "$now" > "$STATE/$IFACE.since" || return 1
    log "$NAME: stale handshake; restarting $IFACE via $BACKEND ($TARGET)"
    if restart_interface; then
        log "$NAME: restart command completed; handshake will be checked next run"
    else
        log "$NAME: restart FAILED; retry after ${threshold}s; check native service logs"
        return 1
    fi
}

if [ "$DISCOVER" = 1 ]; then
    number "$DEFAULT_TIMEOUT" && [ "$DEFAULT_TIMEOUT" -gt 0 ] &&
        [ "$DEFAULT_TIMEOUT" -le 525600 ] || { log 'invalid discovery timeout'; exit 2; }
    devices=$({ for cli in wg awg awg3; do
        have "$cli" || continue
        "$cli" show interfaces 2>/dev/null || :
    done; } | tr ' \t' '\n\n' | sed '/^$/d' | sort -u)
    found=0
    for NAME in $devices; do
        token "$NAME" || continue
        IFACE=$NAME; TOOL=auto; BACKEND=auto; TARGET=-
        if detect_backend && validate_backend && handshake; then
            printf '%s %s %s %s %s\n' "$IFACE" "$DEFAULT_TIMEOUT" "$BACKEND" "$TARGET" "$TOOL"
            found=$((found + 1))
        else log "$NAME: skipped (unsupported/ambiguous manager or no readable peers)"; fi
    done
    [ "$found" -gt 0 ] || exit 1
    exit 0
fi
if [ "$DRY" = 0 ]; then
    [ "$(id -u)" = 0 ] || { log 'run as root (or use --dry-run)'; exit 2; }
    [ ! -L "$STATE" ] || { log 'state directory must not be a symlink'; exit 2; }
    mkdir -p "$STATE" || exit 2
    # mkdir is available on BusyBox and FreeBSD; do not require flock.
    if ! mkdir "$STATE/lock" 2>/dev/null; then
        # Serialize stale-lock reclamation separately, then re-read the PID.
        # Never remove a live invocation's newly-created lock.
        mkdir "$STATE/reap" 2>/dev/null || exit 0
        holder=''
        read -r holder < "$STATE/lock/pid" 2>/dev/null || :
        if number "$holder" && [ "$holder" -gt 0 ] && ! kill -0 "$holder" 2>/dev/null; then
            rm -f "$STATE/lock/pid"
            rmdir "$STATE/lock" 2>/dev/null || { rmdir "$STATE/reap"; exit 0; }
            mkdir "$STATE/lock" 2>/dev/null || { rmdir "$STATE/reap"; exit 0; }
            rmdir "$STATE/reap"
        else rmdir "$STATE/reap"; info 'another invocation holds the lock'; exit 0; fi
    fi
    cleanup() {
        cleanup_status=$?
        trap - 0
        recover_opn_awg || cleanup_status=1
        rm -f "$STATE/lock/pid"
        rmdir "$STATE/lock" 2>/dev/null || :
        exit "$cleanup_status"
    }
    trap cleanup 0
    trap 'exit 1' 1 2 15
    printf '%s\n' "$$" > "$STATE/lock/pid" || exit 2
    recover_opn_awg || exit 1
fi
[ "$RECOVER_ONLY" = 0 ] || exit 0
[ -r "$CONFIG" ] || { log "cannot read config: $CONFIG"; exit 2; }
result=0
seen=' '
while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    set -f
    set -- $line
    set +f
    [ "$#" = 0 ] && continue
    if [ "$#" -lt 2 ] || [ "$#" -gt 5 ]; then log 'invalid config row'; result=1; continue; fi
    case $seen in *" $1 "*) log "duplicate interface: $1"; result=1; continue ;; esac
    seen="$seen$1 "
    check_interface "$@" || result=1
done < "$CONFIG"
exit "$result"
