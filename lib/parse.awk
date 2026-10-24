# Shin4Static list parser (POSIX/busybox awk).
#
# Input: list files; for each file the caller sets -v primary list via the
# "prim" array built from PRIMARIES ("file=primary,file=primary").
# VPNS - space separated indexes of configured VPNs, e.g. "1 2".
#
# Output, tab separated, one line per entry:
#   R <group> <kind> <value> <file:line>     kind: ip | range | asn | domain
#   E <file:line> <message> <raw line>
# group = <primary>.<mode><n>: primary isp|1|2, mode N|K|F, n 0..2

function trim(s) {
	sub(/^[ \t\r]+/, "", s)
	sub(/[ \t\r]+$/, "", s)
	return s
}

# No leading zeros: iprange reads 010 as octal 8, so 010.0.0.0/8 would
# silently become 8.0.0.0/8.
function ipok(s,    n, a, i) {
	n = split(s, a, ".")
	if (n != 4)
		return 0
	for (i = 1; i <= 4; i++)
		if (a[i] !~ /^(0|[1-9][0-9]?[0-9]?)$/ || a[i] + 0 > 255)
			return 0
	return 1
}

# Error text for a bad address: name the leading zero, it is not obvious.
function ipbad(s, what) {
	return s ~ /(^|[^0-9])0[0-9]/ ? what ": ведущий ноль в числе адреса (iprange прочтёт его как восьмеричное)" : what
}

function bad(msg) {
	printf "E\t%s:%d\t%s\t%s\n", fname, FNR, msg, raw
	errors++
}

BEGIN {
	n = split(PRIMARIES, pairs, ",")
	for (i = 1; i <= n; i++) {
		split(pairs[i], kv, "=")
		prim[kv[1]] = kv[2]
	}
	n = split(VPNS, v, " ")
	for (i = 1; i <= n; i++)
		vpn[v[i]] = 1
}

FNR == 1 {
	fname = FILENAME
	sub(/.*\//, "", fname)
	primary = prim[fname]
}

{
	raw = $0
	line = $0
	sub(/\r$/, "", line)
	if (line ~ /^[ \t]*([#;]|$)/)
		next
	sub(/[ \t]+[#;].*$/, "", line)
	line = trim(line)

	mode = "N"
	fb = 0
	if (substr(line, 1, 1) == "!") {
		tag = line
		sub(/[ \t].*$/, "", tag)
		line = trim(substr(line, length(tag) + 1))
		utag = toupper(tag)
		if (utag ~ /^!KS[0-9]$/) {
			mode = "K"
			fb = substr(utag, 4) + 0
		} else if (utag ~ /^!FB[0-9]$/) {
			mode = "F"
			fb = substr(utag, 4) + 0
			if (fb == 0) {
				bad("!FB0 не имеет смысла: используйте строку без метки")
				next
			}
		} else {
			bad("неизвестная метка " tag " (допустимы !KS0, !KS<n>, !FB<n>)")
			next
		}
		if (fb != 0 && fb "" == primary) {
			bad("метка " tag " ссылается на основной выход этого же списка")
			next
		}
		if (fb != 0 && !(fb in vpn)) {
			bad("метка " tag ": VPN" fb " не настроен")
			next
		}
		if (line == "") {
			bad("после метки нет записи")
			next
		}
	}

	if (line ~ /[ \t]/ && line !~ /^[0-9.]+[ \t]*-[ \t]*[0-9.]+$/) {
		bad("в строке больше одной записи")
		next
	}

	group = primary "." mode fb
	where = fname ":" FNR

	if (line ~ /^[Aa][Ss][0-9]+$/) {
		num = substr(line, 3)
		sub(/^0+/, "", num)
		if (num == "" || length(num) > 10 || num + 0 > 4294967295) {
			bad("неверный номер AS")
			next
		}
		printf "R\t%s\tasn\tAS%s\t%s\n", group, num, where
		next
	}

	if (line ~ /^[0-9.]+[ \t]*-[ \t]*[0-9.]+$/) {
		split(line, r, /[ \t]*-[ \t]*/)
		if (!ipok(r[1]) || !ipok(r[2])) {
			bad(ipbad(line, "неверный диапазон адресов"))
			next
		}
		printf "R\t%s\trange\t%s - %s\t%s\n", group, r[1], r[2], where
		next
	}

	if (line ~ /^[0-9.]+\/[0-9]+$/) {
		split(line, c, "/")
		if (!ipok(c[1]) || c[2] + 0 > 32) {
			bad(ipbad(c[1], "неверная подсеть"))
			next
		}
		if (c[2] + 0 < 8)
			printf "W\t%s\tслишком широкая подсеть /%s\t%s\n", where, c[2], raw
		split(c[1], o, ".")
		addr = ((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4]
		size = 2 ^ (32 - c[2])
		if (addr % size != 0) {
			base = addr - addr % size
			printf "W\t%s\t%s — не начало подсети, будет взята %d.%d.%d.%d/%d\t%s\n", where, line, \
				int(base / 16777216), int(base / 65536) % 256, int(base / 256) % 256, base % 256, c[2], raw
		}
		printf "R\t%s\tip\t%s\t%s\n", group, line, where
		next
	}

	if (line ~ /^[0-9.]+$/) {
		if (!ipok(line)) {
			bad(ipbad(line, "неверный IPv4-адрес"))
			next
		}
		printf "R\t%s\tip\t%s\t%s\n", group, line, where
		next
	}

	if (line ~ /:\/\//) {
		bad("это URL: укажите только имя домена")
		next
	}
	if (line ~ /^\*/) {
		bad("маски доменов (*.) не поддерживаются: резолвится только точное имя")
		next
	}
	if (line ~ /:/) {
		bad("IPv6 и host:port не поддерживаются")
		next
	}

	dom = tolower(line)
	sub(/\.$/, "", dom)
	if (dom ~ /^([a-z0-9_]([a-z0-9_-]*[a-z0-9_])?\.)+[a-z]([a-z0-9-]*[a-z0-9])?$/ && length(dom) <= 253) {
		printf "R\t%s\tdomain\t%s\t%s\n", group, dom, where
		next
	}

	bad("не IPv4, не подсеть, не диапазон, не домен и не AS")
}
