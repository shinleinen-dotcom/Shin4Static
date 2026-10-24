# Shin4Static: lists -> groups -> BIRD route files.
#
# Group key: <primary>.<mode><n>, e.g. "1.K2" = VPN1, then VPN2, then block.
# Work files in $WORK:
#   in/<key>       raw IPv4 entries of the group (ip, cidr, "a - b")
#   in/<key>.n     number of list entries of the group
#   grp/<key>      aggregated CIDRs after overlap removal

# Strictness rank for overlap resolution: isp first, then !KS0, !KS<n>,
# !FB<n>, untagged; ties by primary (1 before 2).
group_rank() {
	_p=${1%%.*}
	_m=${1#*.}
	if [ "$_p" = isp ]; then
		_r=0
	else
		case "$_m" in
			K0) _r=1 ;;
			K*) _r=2 ;;
			F*) _r=3 ;;
			*) _r=4 ;;
		esac
	fi
	echo "$_r$_p $1"
}

parse_lists() {
	_files=
	_prim=
	for _f in isp:isp 1:vpn1 2:vpn2; do
		_p=${_f%%:*}
		_name=${_f#*:}.list
		[ -f "$S4S_LISTS/$_name" ] || continue
		if [ "$_p" = 2 ] && [ -z "$VPN2" ]; then
			if grep -qvE '^[[:space:]]*([#;]|$)' "$S4S_LISTS/$_name"; then
				warn "$_name не пуст, но VPN2 не настроен — список пропущен"
			fi
			continue
		fi
		_files="$_files $S4S_LISTS/$_name"
		_prim="$_prim${_prim:+,}$_name=$_p"
	done
	[ -n "$_files" ] || return 0
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
}

# Aggregate each group; an empty result for a group that has entries falls
# back to the last good result of that group.
aggregate_groups() {
	for _cnt in "$WORK"/in/*.n; do
		[ -e "$_cnt" ] || continue
		_key=$(basename "$_cnt" .n)
		: > "$WORK/grp/$_key.raw"
		if [ -s "$WORK/in/$_key" ]; then
			"$IPRANGE" "$WORK/in/$_key" > "$WORK/grp/$_key.raw" 2>"$WORK/iprange.err" ||
				warn "группа $_key: iprange: $(head -1 "$WORK/iprange.err")"
		fi
		if [ ! -s "$WORK/grp/$_key.raw" ]; then
			if [ -s "$S4S_STATE/groups/$_key" ]; then
				warn "группа «$(describe_group "$_key")»: адресов не получено, оставляю прежние"
				cp "$S4S_STATE/groups/$_key" "$WORK/grp/$_key.raw"
			else
				warn "группа «$(describe_group "$_key")»: адресов не получено"
			fi
		fi
		[ "$DRY_RUN" = 1 ] || [ ! -s "$WORK/grp/$_key.raw" ] ||
			cp "$WORK/grp/$_key.raw" "$S4S_STATE/groups/$_key"
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
			"$IPRANGE" --common "$_src" "$WORK/taken" > "$WORK/overlap" 2>/dev/null
			if [ -s "$WORK/overlap" ]; then
				warn "«$(describe_group "$_key")» пересекается с более строгими правилами ($(wc -l < "$WORK/overlap" | tr -d ' ') сетей, например $(head -1 "$WORK/overlap")) — они остаются за более строгими"
				"$IPRANGE" "$_src" --exclude-next "$WORK/taken" > "$WORK/grp/$_key"
			else
				cp "$_src" "$WORK/grp/$_key"
			fi
		else
			cp "$_src" "$WORK/grp/$_key"
		fi
		[ -s "$WORK/grp/$_key" ] || continue
		"$IPRANGE" "$WORK/taken" "$WORK/grp/$_key" > "$WORK/taken.new"
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
	"$IPRANGE" --print-prefix 'route ' --print-suffix-nets "$_sfx" --print-suffix-ips "/32$_sfx" "$1"
}

isp_target() {
	case "$ISP_GW" in
		'') echo "$ISP" ;;
		auto)
			_gw=$("$IP" route show 2>/dev/null | awk -v dev="$ISP" '$0 ~ " dev " dev "( |$)" && / via / { for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }')
			if [ -n "$_gw" ]; then
				echo "$_gw"
			else
				warn "ISP_GW=auto: шлюз провайдера не найден, маршруты пойдут прямо на $ISP"
				echo "$ISP"
			fi ;;
		*) echo "$ISP_GW" ;;
	esac
}

write_route_files() {
	_out=$1
	mkdir -p "$_out"
	: > "$_out/step1.routes"
	: > "$_out/step2.routes"
	: > "$_out/ks.routes"
	_isp=$(isp_target)
	for _g in "$WORK"/grp/*; do
		case "$_g" in *.raw) continue ;; esac
		[ -s "$_g" ] || continue
		_key=$(basename "$_g")
		_p=${_key%%.*}
		_m=${_key#*.}
		_n=${_m#?}
		_m=${_m%?}
		if [ "$_p" = isp ]; then
			_t1=$_isp
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
	collect_groups
	aggregate_groups
	resolve_overlaps
	write_route_files "$1"
	write_bird_include "$1"
}
