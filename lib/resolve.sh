# Shin4Static: turning domains and AS numbers into IPv4 prefixes.

# Private and special-use networks, never taken from AS sources.
BOGONS='0.0.0.0/8
10.0.0.0/8
100.64.0.0/10
127.0.0.0/8
169.254.0.0/16
172.16.0.0/12
192.0.0.0/24
192.0.2.0/24
192.168.0.0/16
198.18.0.0/15
198.51.100.0/24
203.0.113.0/24
224.0.0.0/3'

# Wait until DNS answers, at most DNS_WAIT seconds. Returns 1 on timeout.
dns_ready() {
	[ -n "$DNS_OK" ] && return "$DNS_OK"
	_waited=0
	while :; do
		if [ -n "$(printf 'one.one.one.one\n' | "$IPRANGE" - 2>/dev/null)" ]; then
			DNS_OK=0
			return 0
		fi
		if [ "$_waited" -ge "$DNS_WAIT" ]; then
			DNS_OK=1
			warn "DNS не отвечает ${DNS_WAIT} с — домены не обновлены"
			return 1
		fi
		sleep 5
		_waited=$((_waited + 5))
	done
}

# Resolve one domain to IPv4 addresses. One iprange call per name, so a dead
# name cannot take the whole list down (iprange 2.x rejects the whole input).
resolve_domain() {
	dns_ready || return 1
	printf '%s\n' "$1" | "$IPRANGE" - 2>/dev/null
}

# Keep only IPv4 prefixes not wider than ASN_MIN_PREFIX and not bogons.
asn_filter() {
	_in=$1
	_out=$2
	awk -v min="$ASN_MIN_PREFIX" -F/ 'NF == 2 && $2 + 0 >= min + 0 && $2 + 0 <= 32 { print }' "$_in" > "$_in.f"
	printf '%s\n' "$BOGONS" > "$WORK/bogons"
	if [ -s "$_in.f" ]; then
		"$IPRANGE" "$_in.f" --exclude-next "$WORK/bogons" > "$_out" 2>/dev/null
	else
		: > "$_out"
	fi
}

asn_fetch_url() {
	"$CURL" -fsS --connect-timeout 10 --max-time "$CURL_TIMEOUT" "$1" 2>/dev/null |
		grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}'
}

# Print prefixes of an AS (e.g. AS13335), using a cache with ASN_TTL.
asn_prefixes() {
	_as=$1
	_num=${_as#AS}
	_cache=$S4S_STATE/asn/$_as
	if [ -s "$_cache" ] && [ $(($(date +%s) - $(date -r "$_cache" +%s 2>/dev/null || echo 0))) -lt "$ASN_TTL" ]; then
		debug "$_as: из кэша"
		cat "$_cache"
		return 0
	fi

	_raw=$WORK/asn_$_as
	for _url in \
		"https://stat.ripe.net/data/announced-prefixes/data.json?resource=$_as" \
		"https://api.routeviews.org/guest/asn/$_num?af=4"; do
		asn_fetch_url "$_url" > "$_raw"
		if [ -s "$_raw" ]; then
			asn_filter "$_raw" "$_raw.ok"
			if [ -s "$_raw.ok" ]; then
				debug "$_as: $(wc -l < "$_raw.ok") префиксов ($_url)"
				[ "$DRY_RUN" = 1 ] || cp "$_raw.ok" "$_cache"
				cat "$_raw.ok"
				return 0
			fi
		fi
	done

	if [ -s "$_cache" ]; then
		warn "$_as: источники не ответили, использую кэш от $(date -r "$_cache" '+%Y-%m-%d %H:%M' 2>/dev/null)"
		cat "$_cache"
		return 0
	fi
	return 1
}
