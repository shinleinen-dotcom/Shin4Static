# Shin4Static: lists -> groups -> BIRD route files.
#
# Group key: <primary>.<mode><n>, e.g. "1.K2" = VPN1, then VPN2, then block.
# Work files in $WORK:
#   in/<key>       raw IPv4 entries of the group (ip, cidr, "a - b")
#   in/<key>.n     number of list entries of the group
#   grp/<key>      aggregated CIDRs after overlap removal

# Strictness rank for overlap resolution: isp first, then !KS0, !KS<n>,
# !FB<n>, untagged; ties by primary (1 before 2). Inside isp.list the same
# order of tags.
group_rank() {
	_p=${1%%.*}
	_m=${1#*.}
	case "$_m" in
		K0) _r=1 ;;
		K*) _r=2 ;;
		F*) _r=3 ;;
		*) _r=4 ;;
	esac
	if [ "$_p" = isp ]; then
		echo "0${_r}isp $1"
	else
		echo "$_r$_p $1"
	fi
}

# iprange must work: with a broken one every group comes out empty, and
# installing that would drop all routes, the kill switch included.
iprange_ok() {
	[ "$(printf '192.0.2.1\n' | "$IPRANGE" - 2>/dev/null)" = 192.0.2.1 ] ||
		die "iprange ($IPRANGE) не работает — маршруты не тронуты"
}

# Run iprange; on failure stop the whole run, nothing is installed.
ipr() {
	"$IPRANGE" "$@" 2>"$WORK/iprange.err" ||
		die "iprange $*: $(head -1 "$WORK/iprange.err") — маршруты не тронуты"
}

# parse_lists [dir]: the lists in $S4S_LISTS (or dir, same file names).
parse_lists() {
	_dir=${1:-$S4S_LISTS}
	_files=
	_prim=
	for _f in isp:isp 1:vpn1 2:vpn2; do
		_p=${_f%%:*}
		_name=${_f#*:}.list
		[ -f "$_dir/$_name" ] || continue
		if [ "$_p" = 2 ] && [ -z "$VPN2" ]; then
			if grep -qvE '^[[:space:]]*([#;]|$)' "$_dir/$_name"; then
				warn "$_name не пуст, но VPN2 не настроен — список пропущен"
			fi
			continue
		fi
		_files="$_files $_dir/$_name"
		_prim="$_prim${_prim:+,}$_name=$_p"
	done
	[ -n "$_files" ] || return 0
	# Disabled entries ("#off ...") are comments for the parser; just say so.
	# shellcheck disable=SC2086
	_off=$(cat $_files | grep -c '^[[:blank:]]*#[Oo][Ff][Ff][[:blank:]]')
	[ "$_off" = 0 ] || info "отключённых записей (#off): $_off — не применяются"
	# shellcheck disable=SC2086
	awk -v PRIMARIES="$_prim" -v VPNS="$VPNS" -f "$S4S_LIB/parse.awk" $_files
}

collect_groups() {
	mkdir -p "$WORK/in" "$WORK/grp"
	parse_lists > "$WORK/parsed"

	while IFS='	' read -r _t _a _b _c _d; do
		case "$_t" in
			E) err "$_a: $_b: $_c" ;;
			W) warn "$_a: $_b" ;;
		esac
	done < "$WORK/parsed"

	grep '^R	' "$WORK/parsed" > "$WORK/records"
	while IFS='	' read -r _t _key _kind _val _where; do
		_n=$(cat "$WORK/in/$_key.n" 2>/dev/null || echo 0)
		echo $((_n + 1)) > "$WORK/in/$_key.n"
		case "$_kind" in
			ip|range)
				printf '%s\n' "$_val" >> "$WORK/in/$_key" ;;
			domain)
				if resolve_domain "$_val" > "$WORK/one"; [ -s "$WORK/one" ]; then
					cat "$WORK/one" >> "$WORK/in/$_key"
					debug "$_where $_val: $(wc -l < "$WORK/one" | tr -d ' ') адр."
				else
					warn "$_where: домен $_val не разрезолвился"
				fi ;;
			asn)
				if asn_prefixes "$_val" > "$WORK/one" && [ -s "$WORK/one" ]; then
					cat "$WORK/one" >> "$WORK/in/$_key"
				else
					warn "$_where: для $_val не получено ни одного префикса"
				fi ;;
		esac
	done < "$WORK/records"

	# Forget the addresses of domains no longer in the lists.
	if [ "$DRY_RUN" != 1 ]; then
		awk -F '\t' '$3 == "domain" { print $4 }' "$WORK/records" > "$WORK/domains"
		for _c in "$S4S_STATE"/dns/*; do
			[ -f "$_c" ] || continue
			grep -qxF "${_c##*/}" "$WORK/domains" || rm -f "$_c"
		done
	fi
}

aggregate_groups() {
	for _cnt in "$WORK"/in/*.n; do
		[ -e "$_cnt" ] || continue
		_key=$(basename "$_cnt" .n)
		: > "$WORK/grp/$_key.raw"
		if [ -s "$WORK/in/$_key" ]; then
			ipr "$WORK/in/$_key" > "$WORK/grp/$_key.raw"
		fi
		[ -s "$WORK/grp/$_key.raw" ] || warn "группа «$(describe_group "$_key")»: адресов не получено"
	done
}

# Make groups disjoint: each address stays with the strictest group.
resolve_overlaps() {
	: > "$WORK/taken"
	for _raw in "$WORK"/grp/*.raw; do
		[ -e "$_raw" ] || continue
		group_rank "$(basename "$_raw" .raw)"
	done | sort > "$WORK/order"
	while read -r _rank _key; do
		_src=$WORK/grp/$_key.raw
		if [ -s "$WORK/taken" ] && [ -s "$_src" ]; then
			ipr --common "$_src" "$WORK/taken" > "$WORK/overlap"
			if [ -s "$WORK/overlap" ]; then
				warn "«$(describe_group "$_key")» пересекается с более строгими правилами ($(wc -l < "$WORK/overlap" | tr -d ' ') сетей, например $(head -1 "$WORK/overlap")) — они остаются за более строгими"
				ipr "$_src" --exclude-next "$WORK/taken" > "$WORK/grp/$_key"
			else
				cp "$_src" "$WORK/grp/$_key"
			fi
		else
			cp "$_src" "$WORK/grp/$_key"
		fi
		[ -s "$WORK/grp/$_key" ] || continue
		ipr "$WORK/taken" "$WORK/grp/$_key" > "$WORK/taken.new"
		mv "$WORK/taken.new" "$WORK/taken"
	done < "$WORK/order"
}

# Print BIRD static routes for a CIDR file: emit_routes <file> <target>
# target: interface name, gateway IP or "unreachable".
emit_routes() {
	case "$2" in
		unreachable) _sfx=' unreachable;' ;;
		*[!0-9.]*) _sfx=" via \"$2\";" ;;
		*) _sfx=" via $2;" ;;
	esac
	ipr --print-prefix 'route ' --print-suffix-nets "$_sfx" --print-suffix-ips "/32$_sfx" "$1"
}

# Target for isp.list routes into ISP_TARGET. With ISP_GW=auto the last
# gateway seen is remembered: right after boot or while the provider is down
# there is no default route, and "via eth3" without a gateway would make the
# addresses in isp.list (VPN servers) unreachable once the provider is back.
isp_target() {
	case "$ISP_GW" in
		'') ISP_TARGET=$ISP ;;
		auto)
			ISP_TARGET=$("$IP" route show 2>/dev/null | awk -v dev="$ISP" '$0 ~ " dev " dev "( |$)" && / via / { for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }')
			if [ -n "$ISP_TARGET" ]; then
				[ "$DRY_RUN" = 1 ] || echo "$ISP_TARGET" > "$S4S_STATE/isp_gw"
			else
				ISP_TARGET=$(cat "$S4S_STATE/isp_gw" 2>/dev/null)
				case "$ISP_TARGET" in
					''|*[!0-9.]*)
						warn "ISP_GW=auto: шлюз провайдера не найден, маршруты пойдут прямо на $ISP"
						ISP_TARGET=$ISP ;;
					*) warn "ISP_GW=auto: сейчас шлюза провайдера нет, беру прежний $ISP_TARGET" ;;
				esac
			fi ;;
		*) ISP_TARGET=$ISP_GW ;;
	esac
}

write_route_files() {
	_out=$1
	mkdir -p "$_out"
	: > "$_out/step1.routes"
	: > "$_out/step2.routes"
	: > "$_out/ks.routes"
	ISP_TARGET=
	for _g in "$WORK"/grp/*; do
		case "$_g" in *.raw) continue ;; esac
		[ -s "$_g" ] || continue
		_key=$(basename "$_g")
		_p=${_key%%.*}
		_m=${_key#*.}
		_n=${_m#?}
		_m=${_m%?}
		if [ "$_p" = isp ]; then
			[ -n "$ISP_TARGET" ] || isp_target
			_t1=$ISP_TARGET
		else
			_t1=$(exit_iface "$_p")
		fi
		{
			echo "# $(describe_group "$_key")"
			emit_routes "$_g" "$_t1"
		} >> "$_out/step1.routes"
		if [ "$_n" != 0 ]; then
			{
				echo "# $(describe_group "$_key")"
				emit_routes "$_g" "$(exit_iface "$_n")"
			} >> "$_out/step2.routes"
		fi
		if [ "$_m" = K ]; then
			{
				echo "# $(describe_group "$_key")"
				emit_routes "$_g" unreachable
			} >> "$_out/ks.routes"
		fi
	done
}

# Groups as applied, for "shin4static why".
save_groups() {
	rm -rf "$S4S_STATE/groups.new"
	mkdir -p "$S4S_STATE/groups.new"
	for _g in "$WORK"/grp/*; do
		case "$_g" in *.raw) continue ;; esac
		[ -s "$_g" ] && cp "$_g" "$S4S_STATE/groups.new/"
	done
	rm -rf "$S4S_STATE/groups"
	mv "$S4S_STATE/groups.new" "$S4S_STATE/groups"
}

# BIRD protocols for the tables; regenerated from settings on every run.
write_bird_include() {
	cat > "$1/shin4static.conf" <<EOF
# Generated by shin4static from $S4S_CONF. Do not edit.

ipv4 table s4s_step1;
ipv4 table s4s_step2;
ipv4 table s4s_ks;

protocol static s4s_static_step1 {
	ipv4 { table s4s_step1; };
	include "$S4S_GEN/step1.routes";
}
protocol static s4s_static_step2 {
	ipv4 { table s4s_step2; };
	include "$S4S_GEN/step2.routes";
}
protocol static s4s_static_ks {
	ipv4 { table s4s_ks; };
	include "$S4S_GEN/ks.routes";
}

protocol kernel s4s_kernel_step1 {
	kernel table $TABLE_STEP1;
	scan time 300;
	persist;
	ipv4 { table s4s_step1; import none; export all; };
}
protocol kernel s4s_kernel_step2 {
	kernel table $TABLE_STEP2;
	scan time 300;
	persist;
	ipv4 { table s4s_step2; import none; export all; };
}
protocol kernel s4s_kernel_ks {
	kernel table $TABLE_KS;
	scan time 300;
	persist;
	ipv4 { table s4s_ks; import none; export all; };
}
EOF
}

# Full generation into directory $1.
generate() {
	iprange_ok
	collect_groups
	aggregate_groups
	resolve_overlaps
	write_route_files "$1"
	write_bird_include "$1"
}
