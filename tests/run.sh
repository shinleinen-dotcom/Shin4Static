#!/bin/sh
# Shin4Static tests: run the generator against a temporary root with mocked
# curl, birdc, bird and ip. Needs a real iprange in PATH (or IPRANGE=...) and DNS.
#   sh tests/run.sh

REPO=$(dirname "$(dirname "$(readlink -f "$0")")")
T=$(mktemp -d /tmp/s4s-test.XXXXXX)
trap 'rm -rf "$T"' EXIT
FAILS=0

ok()   { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

export S4S_ROOT=$T/opt
export S4S_LIB=$REPO/lib
export S4S_SOCK=
REAL_IPRANGE=$(command -v "${IPRANGE:-iprange}") || { echo "нужен iprange (IPRANGE=...)"; exit 1; }
mkdir -p "$T/mock" "$S4S_ROOT/etc/shin4static/lists"

# iprange: the real one, except for names in $T/dns.fail (no answer), names
# in $T/dns.sink (DNS filter answer 0.0.0.0) and $T/iprange.broken (dead).
cat > "$T/mock/iprange" <<EOF
#!/bin/sh
[ -e "$T/iprange.broken" ] && exit 127
if [ "\$1" = - ] && [ \$# = 1 ]; then
	_in=\$(cat)
	[ -e "$T/dns.fail" ] && grep -qxF "\$_in" "$T/dns.fail" && exit 0
	[ -e "$T/dns.sink" ] && grep -qxF "\$_in" "$T/dns.sink" && { echo 0.0.0.0; exit 0; }
	printf '%s\n' "\$_in" | exec "$REAL_IPRANGE" -
fi
exec "$REAL_IPRANGE" "\$@"
EOF
# curl: AS fixture to -o; $T/curl.fail - error, $T/curl.partial - answer cut
# by the timeout (part of the data, exit 28).
cat > "$T/mock/curl" <<EOF
#!/bin/sh
_o=/dev/stdout
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && { _o=\$2; shift; }; shift; done
[ -e "$T/curl.fail" ] && exit 22
if [ -e "$T/curl.partial" ]; then
	echo '{"data":{"prefixes":[{"prefix":"93.184.217.0/24"}' > "\$_o"
	exit 28
fi
echo '{"data":{"prefixes":[{"prefix":"93.184.216.0/24"},{"prefix":"10.0.0.0/8"},{"prefix":"0.0.0.0/0"},{"prefix":"5.0.0.0/4"},{"prefix":"2606:2800::/32"}]}}' > "\$_o"
EOF
# birdc: running unless $T/bird.down; "configure check" fails if $T/bird.bad,
# "configure" fails if $T/bird.noreconf.
cat > "$T/mock/birdc" <<EOF
#!/bin/sh
echo "\$*" >> "$T/birdc.calls"
case "\$*" in
	"show status") [ -e "$T/bird.down" ] && exit 1; exit 0 ;;
	"configure check") [ -e "$T/bird.bad" ] && { echo "syntax error"; exit 1; }; echo "Configuration OK" ;;
	configure) [ -e "$T/bird.noreconf" ] && { echo "Unable to open configuration file"; exit 0; }; echo "Reconfigured" ;;
esac
EOF
cat > "$T/mock/bird" <<EOF
#!/bin/sh
echo started >> "$T/bird.calls"
rm -f "$T/bird.down"
EOF
# ip: default route unless $T/nogw; "rule del" fails, so loops end.
cat > "$T/mock/ip" <<EOF
#!/bin/sh
echo "\$*" >> "$T/ip.calls"
case "\$*" in
	"route show") [ -e "$T/nogw" ] || echo "default via 192.0.2.1 dev eth3" ;;
	"rule del"*) exit 1 ;;
	"rule show") [ -e "$T/rules" ] && cat "$T/rules" ;;
	"route get "*) if [ -e "$T/route" ]; then cat "$T/route"; else echo "\$3 dev nwg0 table 1031 src 10.8.1.5"; fi ;;
esac
exit 0
EOF
chmod +x "$T/mock/"*
export IPRANGE=$T/mock/iprange CURL=$T/mock/curl BIRDC=$T/mock/birdc BIRD=$T/mock/bird IP=$T/mock/ip

CONF=$S4S_ROOT/etc/shin4static/shin4static.conf
L=$S4S_ROOT/etc/shin4static/lists
GEN=$S4S_ROOT/etc/shin4static/gen
STATE=$S4S_ROOT/var/shin4static
s4s() { sh "$REPO/bin/shin4static" "$@"; }
# not_blocked IP: the address is not inside any unreachable net of ks.routes.
not_blocked() {
	sed -n 's/^route \([^ ]*\) unreachable;$/\1/p' "$GEN/ks.routes" > "$T/ksnets"
	[ -z "$(printf '%s\n' "$1" | "$REAL_IPRANGE" --common - "$T/ksnets" 2>/dev/null)" ]
}

cat > "$CONF" <<EOF
ISP=eth3
ISP_GW=auto
VPN1=nwg0
VPN2=
DNS_WAIT=5
EOF

cat > "$L/isp.list" <<'EOF'
198.51.100.10
EOF
cat > "$L/vpn1.list" <<'EOF'
# comment
198.51.0.0/16          ; wide, untagged
!KS0 198.51.100.0/24
!ks0 as13335
one.one.one.one
!KS0 nonexistent-s4s-test.invalid
https://example.com/x
*.example.com
300.1.1.1
010.20.30.0/24
!XX 1.1.1.1
!KS1 1.1.1.1
!KS2 1.1.1.1
!FB0 1.1.1.1
1.2.3.4 5.6.7.8
32.0.0.0/7
45.1.2.3/24
192.0.2.1 - 192.0.2.6
EOF
cat > "$L/vpn2.list" <<'EOF'
8.8.8.8
EOF

echo "== check (parse, overlaps, nothing written)"
s4s check > "$T/out" 2>&1
cat "$T/out"
check "check exits non-zero on bad lines" "! s4s check -q >/dev/null 2>&1"
for msg in "это URL" "маски доменов" "неверный IPv4" "ведущий ноль" "неизвестная метка" "основной выход этого же" "VPN2 не настроен" "!FB0" "больше одной записи" "слишком широкая" "будет взята 45.1.2.0/24" "vpn2.list не пуст" "nonexistent-s4s-test.invalid не разрезолвился" "пересекается"; do
	check "message: $msg" "grep -qF '$msg' '$T/out'"
done
check "check wrote nothing" "[ ! -e '$GEN/step1.routes' ]"

echo "== update"
s4s update > "$T/out" 2>&1
cat "$T/out"
check "step1 has KS0 net via nwg0" "grep -q 'route 198.51.100.0/24 via \"nwg0\";' '$GEN/step1.routes' || grep -q 'route 198.51.100.0/2[5-9] via \"nwg0\";' '$GEN/step1.routes'"
check "isp address via gateway" "grep -q 'route 198.51.100.10/32 via 192.0.2.1;' '$GEN/step1.routes'"
check "KS0 net blocked" "! not_blocked 198.51.100.11"
check "isp address removed from KS0 group" "not_blocked 198.51.100.10"
check "KS0 /24 not in untagged group" "! awk '/^# VPN1\(nwg0\) → провайдер/{f=1;next} /^#/{f=0} f' '$GEN/step1.routes' | grep -q '198.51.100.'"
check "leading-zero net not routed" "! grep -q '8.20.30.0' '$GEN/step1.routes' && ! grep -q '10.20.30.0' '$GEN/step1.routes'"
check "AS prefix kept" "grep -q '93.184.216.0/24' '$GEN/ks.routes'"
check "AS bogon dropped" "! grep -q '10.0.0.0/8' '$GEN/step1.routes'"
check "AS default dropped" "! grep -q ' 0.0.0.0/' '$GEN/step1.routes'"
check "AS too wide dropped" "! grep -q '5.0.0.0/4' '$GEN/step1.routes'"
check "range converted" "grep -q '192.0.2.4/31' '$GEN/step1.routes'"
check "domain resolved" "grep -q '1.1.1.1/32 via \"nwg0\"' '$GEN/step1.routes'"
check "step2 empty without fallbacks" "[ ! -s '$GEN/step2.routes' ]"
check "bird include has tables" "grep -q 'kernel table 1039' '$GEN/shin4static.conf'"
check "kernel routes persist" "[ \$(grep -c 'persist;' '$GEN/shin4static.conf') = 3 ]"
check "system bird.conf untouched" "[ ! -e '$S4S_ROOT/etc/bird.conf' ]"
check "bird reconfigured" "grep -qx configure '$T/birdc.calls'"
check "ip rules ensured" "grep -q 'rule add table 1039 priority 30039' '$T/ip.calls'"
check "gateway remembered" "[ \"\$(cat '$STATE/isp_gw')\" = 192.0.2.1 ]"

echo "== update again: nothing changed"
: > "$T/birdc.calls"
s4s update > "$T/out" 2>&1
check "no reconfigure when unchanged" "! grep -qx configure '$T/birdc.calls'"
check "says unchanged" "grep -q 'не изменились' '$T/out'"

echo "== why"
s4s why 198.51.100.11 > "$T/out" 2>&1
cat "$T/out"
check "why: both entries with their lines" "grep -q '^  vpn1.list:2  198.51.0.0/16' '$T/out' && grep -q '^  vpn1.list:3  !KS0 198.51.100.0/24\$' '$T/out'"
check "why: the wider untagged entry marked as not acting" "grep 'vpn1.list:2 ' '$T/out' | grep -q 'не действует'"
check "why: path of the KS0 entry" "grep -qx 'Путь по записи: только через VPN1 (nwg0); если он недоступен — блок (kill switch).' '$T/out'"
check "why: current path in words" "grep -qx 'Сейчас: через VPN1 (nwg0) — основной путь.' '$T/out'"
check "why: no stale warning" "! grep -q 'Внимание' '$T/out'"
s4s why 93.184.216.5 > "$T/out" 2>&1
check "why: AS entry found by its prefixes" "grep -q '^  vpn1.list:4  !ks0 as13335$' '$T/out'"
s4s why 1.1.1.1 > "$T/out" 2>&1
check "why: domain entry found by its addresses" "grep -q 'vpn1.list:5  one.one.one.one' '$T/out'"
printf '5.5.5.5 dev eth3 src 192.0.2.10\n' > "$T/route"
s4s why 5.5.5.5 > "$T/out" 2>&1
check "why: not in lists" "grep -q '^В списках нет' '$T/out' && grep -qx 'Сейчас: через провайдера (eth3) — обычная маршрутизация.' '$T/out'"
printf '198.51.100.11 dev eth3 src 192.0.2.10\n' > "$T/route"
s4s why 198.51.100.11 > "$T/out" 2>&1
check "why: VPN down, untagged would go to provider" "grep -q 'Сейчас: через провайдера (eth3)' '$T/out'"
printf 'RTNETLINK answers: Network is unreachable\n' > "$T/route"
s4s why 198.51.100.11 > "$T/out" 2>&1
check "why: kill switch in words" "grep -q 'Сейчас: заблокирован (kill switch)' '$T/out'"
printf '198.51.100.11 dev nwg0 table 1020 src 10.8.1.5\n' > "$T/route"
printf '30020:\tfrom all lookup 1020\n' > "$T/rules"
s4s why 198.51.100.11 > "$T/out" 2>&1
check "why: foreign rule named" "grep -q 'по чужому правилу (таблица 1020).*30020' '$T/out'"
rm -f "$T/route" "$T/rules"
printf '45.6.7.8\n' >> "$L/vpn1.list"
s4s why 45.6.7.8 > "$T/out" 2>&1
check "why: entry not applied yet" "grep -q 'ещё не применена' '$T/out'"
sed -i '/^45.6.7.8$/d' "$L/vpn1.list"

echo "== disabled entries (#off) stay in the list but are not routed"
printf '#off !KS0 77.88.0.0/16  # пока не нужно\n' >> "$L/vpn1.list"
s4s update > "$T/out" 2>&1
check "disabled entry not routed" "! grep -q '77.88.0.0' '$GEN/step1.routes' && ! grep -q '77.88.0.0' '$GEN/ks.routes'"
check "disabled entries counted" "grep -q 'отключённых записей (#off): 1' '$T/out'"
check "no error for #off line" "! grep -q '77.88' '$T/out'"
cp "$STATE/last.log" "$T/log.before"
s4s why 77.88.1.1 > "$T/out" 2>&1
cat "$T/out"
check "why: disabled entry shown as such" "grep -q 'vpn1.list:19  #off !KS0 77.88.0.0/16  # пока не нужно  — отключена, не действует' '$T/out'"
check "why: nothing active" "grep -q '^Действующих записей нет' '$T/out' && ! grep -q 'Внимание' '$T/out'"
check "why: does not touch the update log" "cmp -s '$STATE/last.log' '$T/log.before'"
sed -i '/^#off !KS0 77.88/d' "$L/vpn1.list"
s4s update -q > /dev/null 2>&1

echo "== AS sources down: cache used"
touch "$T/curl.fail"
s4s update > "$T/out" 2>&1
check "AS still present from cache" "grep -q '93.184.216.0/24' '$GEN/ks.routes'"

echo "== AS cache expired and sources down: stale cache with warning"
printf 'ASN_TTL=0\n' >> "$CONF"
s4s update > "$T/out" 2>&1
check "stale cache warning" "grep -q 'использую кэш' '$T/out'"
check "AS still present" "grep -q '93.184.216.0/24' '$GEN/ks.routes'"

echo "== AS answer cut by timeout: not taken"
rm -f "$T/curl.fail"
touch "$T/curl.partial"
s4s update > "$T/out" 2>&1
check "partial answer refused, cache used" "grep -q 'использую кэш' '$T/out' && grep -q '93.184.216.0/24' '$GEN/ks.routes'"
check "partial prefixes not routed" "! grep -q '93.184.217.0' '$GEN/ks.routes'"
check "cache not overwritten" "grep -q '93.184.216.0/24' '$STATE/asn/AS13335' && ! grep -q '93.184.217.0' '$STATE/asn/AS13335'"
rm -f "$T/curl.partial"

echo "== DNS fails for one name of a mixed KS0 group: its old addresses stay"
printf '!KS0 45.1.2.0/24\n!KS0 one.one.one.one\n' > "$L/vpn1.list"
s4s update -q > /dev/null 2>&1
check "domain blocked by KS0" "! not_blocked 1.1.1.1"
echo one.one.one.one > "$T/dns.fail"
s4s update > "$T/out" 2>&1
check "old addresses of the domain kept" "! not_blocked 1.1.1.1 && grep -q 'route 1.1.1.1/32 via \"nwg0\";' '$GEN/step1.routes'"
check "warned about old addresses" "grep -q 'использую адреса от' '$T/out'"
check "DNS still considered up (other probes)" "! grep -q 'DNS не отвечает' '$T/out'"
rm -f "$T/dns.fail"

echo "== DNS filter answer 0.0.0.0 is not routed"
echo sink.s4s-test.example > "$T/dns.sink"
printf 'sink.s4s-test.example\n' > "$L/vpn1.list"
s4s update > "$T/out" 2>&1
check "sinkhole warned" "grep -q 'блокирует фильтр' '$T/out'"
check "no 0.0.0.0 route" "! grep -q 'route 0.0.0.0' '$GEN/step1.routes'"
check "domain no longer listed: its cache dropped" "[ ! -e '$STATE/dns/one.one.one.one' ]"
rm -f "$T/dns.sink"

echo "== ISP_GW=auto without a gateway now: the last one is used"
touch "$T/nogw"
s4s update > "$T/out" 2>&1
check "isp route still via the old gateway" "grep -q 'route 198.51.100.10/32 via 192.0.2.1;' '$GEN/step1.routes'"
check "warned about old gateway" "grep -q 'беру прежний 192.0.2.1' '$T/out'"
rm -f "$T/nogw"

echo "== fallback tags with VPN2"
sed -i 's/^VPN2=$/VPN2=nwg1/' "$CONF"
printf '!KS2 203.0.113.0/24\n!FB2 192.0.2.0/24\n' > "$L/vpn1.list"
printf '!KS1 198.18.0.0/16\n' > "$L/vpn2.list"
s4s update > "$T/out" 2>&1
check "KS2 step1 via nwg0" "grep -q 'route 203.0.113.0/24 via \"nwg0\";' '$GEN/step1.routes'"
check "KS2 step2 via nwg1" "grep -q 'route 203.0.113.0/24 via \"nwg1\";' '$GEN/step2.routes'"
check "KS2 blocked last" "grep -q 'route 203.0.113.0/24 unreachable;' '$GEN/ks.routes'"
check "FB2 step2 via nwg1" "grep -q 'route 192.0.2.0/24 via \"nwg1\";' '$GEN/step2.routes'"
check "FB2 not blocked" "! grep -q '192.0.2.0/24' '$GEN/ks.routes'"
check "vpn2 KS1 step1 via nwg1" "grep -q 'route 198.18.0.0/16 via \"nwg1\";' '$GEN/step1.routes'"
check "vpn2 KS1 step2 via nwg0" "grep -q 'route 198.18.0.0/16 via \"nwg0\";' '$GEN/step2.routes'"

echo "== isp.list: narrow !KS0 inside a wide !FB1 stays blocked"
printf '!FB1 45.0.0.0/8\n!KS0 45.10.0.0/16\n' > "$L/isp.list"
s4s update > "$T/out" 2>&1
check "KS0 in isp.list wins over FB1" "grep -q 'route 45.10.0.0/16 unreachable;' '$GEN/ks.routes'"
printf '198.51.100.10\n' > "$L/isp.list"
s4s update -q > /dev/null 2>&1

echo "== BIRD rejects config: rollback"
cp "$GEN/step1.routes" "$T/step1.before"
touch "$T/bird.bad"
printf '!KS0 203.0.113.0/24\n' > "$L/vpn1.list"
s4s update > "$T/out" 2>&1
check "error reported" "grep -q 'не принял' '$T/out'"
check "previous routes restored" "cmp -s '$GEN/step1.routes' '$T/step1.before'"
rm -f "$T/bird.bad"

echo "== birdc configure fails: rollback, retried next time"
touch "$T/bird.noreconf"
s4s update > "$T/out" 2>&1
check "configure failure reported" "grep -q 'вернул прежние файлы' '$T/out'"
check "files back to what BIRD runs" "cmp -s '$GEN/step1.routes' '$T/step1.before'"
rm -f "$T/bird.noreconf"
s4s update > "$T/out" 2>&1
check "next run applies" "grep -q 'BIRD перечитал' '$T/out'"

echo "== BIRD crashed: update starts it"
: > "$T/bird.calls"
touch "$T/bird.down"
s4s update > "$T/out" 2>&1
check "bird started" "grep -qx started '$T/bird.calls'"
check "warned" "grep -q 'не работал' '$T/out'"

echo "== iprange broken: nothing installed"
cp -r "$GEN" "$T/gen.before"
touch "$T/iprange.broken"
printf '!KS0 203.0.113.0/24\n5.5.5.5\n' > "$L/vpn1.list"
s4s update > "$T/out" 2>&1
check "update fails" "! s4s update -q >/dev/null 2>&1"
check "iprange error reported" "grep -q 'iprange' '$T/out' && grep -q 'маршруты не тронуты' '$T/out'"
check "routes untouched" "cmp -s '$GEN/ks.routes' '$T/gen.before/ks.routes' && cmp -s '$GEN/step1.routes' '$T/gen.before/step1.routes'"
rm -f "$T/iprange.broken"

echo "== a route file with groups but no routes is never installed"
mkdir -p "$T/bad"
printf '# VPN1(nwg0) → блок\n' > "$T/bad/ks.routes"
: > "$T/bad/step1.routes"
: > "$T/bad/step2.routes"
check "routes_sane refuses" "! (S4S_ROOT='$S4S_ROOT'; . '$REPO/lib/common.sh'; . '$REPO/lib/apply.sh'; routes_sane '$T/bad') 2>/dev/null"

echo "== second run while one is going: busy, code 75"
mkdir "$STATE/lock"
sleep 300 &
echo $! > "$STATE/lock/pid"
s4s update > "$T/out" 2>&1
RC=$?
check "busy exit code 75" "[ $RC = 75 ]"
check "busy message" "grep -q 'уже выполняется' '$T/out'"
kill $! 2>/dev/null
rm -rf "$STATE/lock"

echo "== TABLE/PRIO changed: old rule and table removed"
: > "$T/ip.calls"
printf 'TABLE_KS=1049\nPRIO_KS=30049\n' >> "$CONF"
s4s rules start > "$T/out" 2>&1
check "old rule deleted" "grep -q 'rule del table 1039 priority 30039' '$T/ip.calls'"
check "old table flushed" "grep -q 'route flush table 1039' '$T/ip.calls'"
check "new rule added" "grep -q 'rule add table 1049 priority 30049' '$T/ip.calls'"
check "applied numbers saved" "grep -qx '30049 1049' '$STATE/applied'"

echo "== config with an error: stopping still works"
cp "$CONF" "$T/conf.good"
printf 'ISP=eth3\nif then\n' > "$CONF"
: > "$T/ip.calls"
s4s rules stop > "$T/out" 2>&1
check "rules removed with a broken config" "grep -q 'rule del table 1049 priority 30049' '$T/ip.calls' && grep -q 'rule del table 1031 priority 30031' '$T/ip.calls'"
check "warned about the config" "grep -q 'ошибка в' '$T/out'"
s4s flush > /dev/null 2>&1
check "flush with a broken config" "grep -q 'route flush table 1049' '$T/ip.calls'"
check "update refuses a broken config" "! s4s update -q >/dev/null 2>&1"
cp "$T/conf.good" "$CONF"

echo
if [ "$FAILS" = 0 ]; then echo "Все тесты прошли"; else echo "Провалено: $FAILS"; exit 1; fi
