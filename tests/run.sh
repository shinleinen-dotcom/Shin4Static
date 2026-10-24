#!/bin/sh
# Shin4Static tests: run the generator against a temporary root with mocked
# curl, birdc and ip. Needs a real iprange in PATH (or IPRANGE=...) and DNS.
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
export IPRANGE=${IPRANGE:-iprange}
mkdir -p "$T/mock" "$S4S_ROOT/etc/shin4static/lists"

# curl: AS fixture unless $T/curl.fail exists.
cat > "$T/mock/curl" <<EOF
#!/bin/sh
[ -e "$T/curl.fail" ] && exit 22
echo '{"data":{"prefixes":[{"prefix":"93.184.216.0/24"},{"prefix":"10.0.0.0/8"},{"prefix":"0.0.0.0/0"},{"prefix":"5.0.0.0/4"},{"prefix":"2606:2800::/32"}]}}'
EOF
# birdc: running; "configure check" fails if $T/bird.bad exists.
cat > "$T/mock/birdc" <<EOF
#!/bin/sh
echo "\$*" >> "$T/birdc.calls"
case "\$*" in
	"show status") exit 0 ;;
	"configure check") [ -e "$T/bird.bad" ] && { echo "syntax error"; exit 1; }; echo "Configuration OK" ;;
	configure) echo "Reconfigured" ;;
esac
EOF
cat > "$T/mock/ip" <<'EOF'
#!/bin/sh
case "$*" in
	"route show") echo "default via 192.0.2.1 dev eth3" ;;
esac
EOF
chmod +x "$T/mock/"*
export CURL=$T/mock/curl BIRDC=$T/mock/birdc IP=$T/mock/ip

L=$S4S_ROOT/etc/shin4static/lists
GEN=$S4S_ROOT/etc/shin4static/gen
s4s() { sh "$REPO/bin/shin4static" "$@"; }

cat > "$S4S_ROOT/etc/shin4static/shin4static.conf" <<EOF
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
for msg in "это URL" "маски доменов" "неверный IPv4" "неизвестная метка" "основной выход этого же" "VPN2 не настроен" "!FB0" "больше одной записи" "слишком широкая" "будет взята 45.1.2.0/24" "vpn2.list не пуст" "nonexistent-s4s-test.invalid не разрезолвился" "пересекается"; do
	check "message: $msg" "grep -qF '$msg' '$T/out'"
done
check "check wrote nothing" "[ ! -e '$GEN/step1.routes' ]"

echo "== update"
s4s update > "$T/out" 2>&1
cat "$T/out"
check "step1 has KS0 net via nwg0" "grep -q 'route 198.51.100.0/24 via \"nwg0\";' '$GEN/step1.routes' || grep -q 'route 198.51.100.0/2[5-9] via \"nwg0\";' '$GEN/step1.routes'"
check "isp address via gateway" "grep -q 'route 198.51.100.10/32 via 192.0.2.1;' '$GEN/step1.routes'"
check "isp address removed from KS0 group" "! grep -q 'unreachable' '$GEN/ks.routes' || ! grep -q '198.51.100.10/32 unreachable' '$GEN/ks.routes'"
check "KS0 /24 not in untagged group" "! awk '/^# VPN1\(nwg0\) → провайдер/{f=1;next} /^#/{f=0} f' '$GEN/step1.routes' | grep -q '198.51.100.'"
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

echo "== update again: nothing changed"
: > "$T/birdc.calls"
s4s update > "$T/out" 2>&1
check "no reconfigure when unchanged" "! grep -qx configure '$T/birdc.calls'"
check "says unchanged" "grep -q 'не изменились' '$T/out'"

echo "== AS sources down: cache used"
touch "$T/curl.fail"
rm -f "$S4S_ROOT/var/shin4static/asn/AS13335.tmp"
s4s update > "$T/out" 2>&1
check "AS still present from cache" "grep -q '93.184.216.0/24' '$GEN/ks.routes'"

echo "== AS cache expired and sources down: stale cache with warning"
sed -i 's/^DNS_WAIT=5/DNS_WAIT=5\nASN_TTL=0/' "$S4S_ROOT/etc/shin4static/shin4static.conf"
s4s update > "$T/out" 2>&1
check "stale cache warning" "grep -q 'использую кэш' '$T/out'"
check "AS still present" "grep -q '93.184.216.0/24' '$GEN/ks.routes'"

echo "== group with only dead entries keeps last good result"
printf 'one.one.one.one\n' > "$L/vpn1.list"
s4s update -q > /dev/null 2>&1
printf 'nonexistent-s4s-test.invalid\n' > "$L/vpn1.list"
s4s update > "$T/out" 2>&1
check "kept previous addresses" "grep -q '1.1.1.1/32' '$GEN/step1.routes'"
check "warned about keeping" "grep -q 'оставляю прежние' '$T/out'"

echo "== fallback tags with VPN2"
sed -i 's/^VPN2=$/VPN2=nwg1/' "$S4S_ROOT/etc/shin4static/shin4static.conf"
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

echo "== BIRD rejects config: rollback"
cp "$GEN/step1.routes" "$T/step1.before"
touch "$T/bird.bad"
printf '!KS0 203.0.113.0/24\n' > "$L/vpn1.list"
s4s update > "$T/out" 2>&1
check "error reported" "grep -q 'не принял' '$T/out'"
check "previous routes restored" "cmp -s '$GEN/step1.routes' '$T/step1.before'"
rm -f "$T/bird.bad"

echo
if [ "$FAILS" = 0 ]; then echo "Все тесты прошли"; else echo "Провалено: $FAILS"; exit 1; fi
