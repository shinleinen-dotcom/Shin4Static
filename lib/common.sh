# Shin4Static: paths, settings, logging, locking. Sourced by bin/shin4static.

S4S_ROOT=${S4S_ROOT:-/opt}
S4S_ETC=${S4S_ETC:-$S4S_ROOT/etc/shin4static}
S4S_STATE=${S4S_STATE:-$S4S_ROOT/var/shin4static}
S4S_CONF=${S4S_CONF:-$S4S_ETC/shin4static.conf}
S4S_LISTS=$S4S_ETC/lists
S4S_GEN=$S4S_ETC/gen
S4S_LOG=$S4S_STATE/last.log
S4S_SHARE=${S4S_SHARE:-$S4S_ROOT/share/shin4static}

# Own BIRD instance: a renamed copy of the binaries, own config and socket,
# so the system bird (e.g. Bird4Static) and its init script never touch it.
S4S_BIRD_CONF=$S4S_ETC/bird.conf
S4S_SOCK=${S4S_SOCK-$S4S_ROOT/var/run/shin4static-bird.ctl}
S4S_PIDFILE=$S4S_ROOT/var/run/shin4static-bird.pid
BIRD=${BIRD:-$S4S_SHARE/sbin/s4s-bird}
BIRDC=${BIRDC:-$S4S_SHARE/sbin/s4s-birdc}

IPRANGE=${IPRANGE:-iprange}
CURL=${CURL:-curl}
# Busybox/firmware ip rejects table ids above 255; use full iproute2 (ip-full).
if [ -z "$IP" ]; then
	if [ -x "$S4S_ROOT/sbin/ip" ]; then IP=$S4S_ROOT/sbin/ip; else IP=ip; fi
fi

QUIET=0
VERBOSE=0
WARNINGS=0
ERRORS=0

_log() {
	[ "$DRY_RUN" = 1 ] && return 0
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$S4S_LOG" 2>/dev/null
}

info() {
	[ "$QUIET" = 1 ] || printf '%s\n' "$*" >&2
	_log "$*"
}

debug() {
	[ "$VERBOSE" = 1 ] && printf '  %s\n' "$*" >&2
	return 0
}

warn() {
	WARNINGS=$((WARNINGS + 1))
	printf 'Предупреждение: %s\n' "$*" >&2
	_log "WARN $*"
	command -v logger >/dev/null 2>&1 && logger -t shin4static "WARN $*"
	return 0
}

err() {
	ERRORS=$((ERRORS + 1))
	printf 'Ошибка: %s\n' "$*" >&2
	_log "ERROR $*"
	command -v logger >/dev/null 2>&1 && logger -t shin4static "ERROR $*"
	return 0
}

die() {
	err "$*"
	exit 1
}

s4s_birdc() {
	"$BIRDC" ${S4S_SOCK:+-s "$S4S_SOCK"} "$@"
}

NUM_DEFAULTS='TABLE_STEP1=1031 TABLE_STEP2=1032 TABLE_KS=1039
PRIO_STEP1=30031 PRIO_STEP2=30032 PRIO_KS=30039
ASN_TTL=86400 ASN_MIN_PREFIX=8 CURL_TIMEOUT=60 DNS_WAIT=120'

# load_config [lenient]: lenient is for stopping and cleaning up (uninstall,
# rules stop, flush): a broken or missing config gives defaults and a warning
# instead of leaving BIRD, rules and routes behind.
load_config() {
	_lenient=$1
	_fatal=die
	[ -n "$_lenient" ] && _fatal=warn
	ISP= ISP_GW= VPN1= VPN2=
	eval "$NUM_DEFAULTS"

	if [ ! -f "$S4S_CONF" ]; then
		$_fatal "нет файла настроек $S4S_CONF"
	elif (. "$S4S_CONF") >/dev/null 2>&1; then
		. "$S4S_CONF"
	else
		$_fatal "ошибка в $S4S_CONF: $( (. "$S4S_CONF") 2>&1 >/dev/null | tail -1)"
	fi

	for v in $NUM_DEFAULTS; do
		v=${v%%=*}
		eval "val=\$$v"
		case "$val" in
			''|*[!0-9]*)
				$_fatal "в $S4S_CONF $v должно быть числом, сейчас: '$val'"
				eval "$(printf '%s\n' $NUM_DEFAULTS | grep "^$v=")" ;;
		esac
	done
	# Kernel tables 0 and 253-255 are unspec/default/main/local.
	for v in TABLE_STEP1 TABLE_STEP2 TABLE_KS; do
		eval "val=\$$v"
		case "$val" in
			0|253|254|255) $_fatal "в $S4S_CONF $v=$val — это служебная таблица ядра" ;;
		esac
	done
	if [ "$TABLE_STEP1" = "$TABLE_STEP2" ] || [ "$TABLE_STEP1" = "$TABLE_KS" ] || [ "$TABLE_STEP2" = "$TABLE_KS" ] ||
		[ "$PRIO_STEP1" = "$PRIO_STEP2" ] || [ "$PRIO_STEP1" = "$PRIO_KS" ] || [ "$PRIO_STEP2" = "$PRIO_KS" ]; then
		$_fatal "в $S4S_CONF номера TABLE_* и PRIO_* не должны повторяться"
	fi
	[ -n "$_lenient" ] && return 0

	[ -n "$ISP" ] || die "в $S4S_CONF не задан ISP"
	[ -n "$VPN1" ] || die "в $S4S_CONF не задан VPN1"
	for v in ISP VPN1 VPN2; do
		eval "val=\$$v"
		case "$val" in
			*[!A-Za-z0-9_.-]*) die "в $S4S_CONF $v содержит недопустимые символы: '$val'" ;;
		esac
	done
	case "$ISP_GW" in
		''|auto) ;;
		*[!0-9.]*|*.*.*.*.*) die "в $S4S_CONF ISP_GW должен быть пустым, auto или IPv4-адресом, сейчас: '$ISP_GW'" ;;
	esac

	VPNS=1
	[ -n "$VPN2" ] && VPNS="1 2"
	mkdir -p "$S4S_STATE" "$S4S_STATE/asn" "$S4S_STATE/dns" "$S4S_GEN" 2>/dev/null
}

# Interface for an exit: isp, 1, 2.
exit_iface() {
	case "$1" in
		isp) echo "$ISP" ;;
		1) echo "$VPN1" ;;
		2) echo "$VPN2" ;;
	esac
}

exit_name() {
	case "$1" in
		isp) echo "провайдер($ISP)" ;;
		1) echo "VPN1($VPN1)" ;;
		2) echo "VPN2($VPN2)" ;;
	esac
}

# Human readable chain for a group key like "1.K2".
describe_group() {
	_p=${1%%.*}
	_m=${1#*.}
	_n=${_m#?}
	_m=${_m%?}
	case "$_m" in
		N) if [ "$_p" = isp ]; then
				exit_name isp
			else
				echo "$(exit_name "$_p") → провайдер"
			fi ;;
		K) if [ "$_n" = 0 ]; then
				echo "$(exit_name "$_p") → блок"
			else
				echo "$(exit_name "$_p") → $(exit_name "$_n") → блок"
			fi ;;
		F) echo "$(exit_name "$_p") → $(exit_name "$_n") → провайдер" ;;
	esac
}

# Lock against a second run; stale locks of dead processes are removed.
# Busy: exit code 75, so the web page says "busy" instead of "done".
lock_acquire() {
	_lock=$S4S_STATE/lock
	if ! mkdir "$_lock" 2>/dev/null; then
		_pid=$(cat "$_lock/pid" 2>/dev/null)
		if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
			printf 'Ошибка: уже выполняется обновление (pid %s) — повторите через минуту\n' "$_pid" >&2
			exit 75
		fi
		rm -rf "$_lock"
		mkdir "$_lock" 2>/dev/null || die "не удалось создать блокировку $_lock"
	fi
	echo $$ > "$_lock/pid"
	trap 'rm -rf "$S4S_STATE/lock" "$WORK"' EXIT
	trap 'exit 1' INT TERM HUP
}
