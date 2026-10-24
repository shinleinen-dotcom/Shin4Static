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

# Answers of DNS filters for a blocked name, never routed: 0.0.0.0, 127.x.
DNS_SINKHOLES='0.0.0.0/8
127.0.0.0/8'

# Names to tell "DNS is up" from "this name is dead". Any one is enough:
# a resolver may filter one of them.
DNS_PROBES='one.one.one.one dns.google ya.ru'

# Wait until DNS answers, at most DNS_WAIT seconds. Returns 1 on timeout.
dns_ready() {
	[ -n "$DNS_OK" ] && return "$DNS_OK"
	_waited=0
	while :; do
		for _probe in $DNS_PROBES; do
			if [ -n "$(printf '%s\n' "$_probe" | "$IPRANGE" - 2>/dev/null)" ]; then
				DNS_OK=0
				return 0
			fi
		done
		if [ "$_waited" -ge "$DNS_WAIT" ]; then
			DNS_OK=1
			warn "DNS не отвечает ${DNS_WAIT} с — для доменов взяты прежние адреса"
			return 1
		fi
		sleep 5
		_waited=$((_waited + 5))
	done
}

# Resolve one domain to IPv4 addresses. One iprange call per name, so a dead
# name cannot take the whole list down (iprange 2.x rejects the whole input).
# The last good answer is kept per name: a name that fails this time keeps
# its old addresses (with a warning), so a !KS0 domain does not leak to the
# provider until the next run.
resolve_domain() {
	_dom=$1
	_cache=$S4S_STATE/dns/$_dom
	: > "$WORK/dns.out"
	if dns_ready; then
		printf '%s\n' "$_dom" | "$IPRANGE" - > "$WORK/dns.raw" 2>/dev/null
		if [ -s "$WORK/dns.raw" ]; then
			printf '%s\n' "$DNS_SINKHOLES" > "$WORK/sinkholes"
			"$IPRANGE" "$WORK/dns.raw" --exclude-next "$WORK/sinkholes" > "$WORK/dns.out" 2>/dev/null
			[ -s "$WORK/dns.out" ] || warn "домен $_dom: DNS вернул только 0.0.0.0/127.x — похоже, его блокирует фильтр"
		fi
	fi
	if [ -s "$WORK/dns.out" ]; then
		[ "$DRY_RUN" = 1 ] || cp "$WORK/dns.out" "$_cache"
		cat "$WORK/dns.out"
		return 0
	fi
	if [ -s "$_cache" ]; then
		warn "домен $_dom не разрезолвился, использую адреса от $(date -r "$_cache" '+%Y-%m-%d %H:%M' 2>/dev/null)"
		cat "$_cache"
		return 0
	fi
	return 1
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

# The whole answer or nothing: an answer cut by --max-time or a dropped
# connection must not be taken (and cached for a day) as the full list.
asn_fetch_url() {
	"$CURL" -fsS --connect-timeout 10 --max-time "$CURL_TIMEOUT" -o "$WORK/asn.body" "$1" 2>/dev/null || return 1
	grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}' "$WORK/asn.body"
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
		asn_fetch_url "$_url" > "$_raw" || continue
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
