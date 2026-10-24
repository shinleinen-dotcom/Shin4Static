#!/bin/sh
# Dev fixture for the web UI: a fake /opt under /tmp/s4s-dev with sample lists
# and mocked curl/birdc/ip; real shin4static and iprange.
#   IPRANGE=/path/to/iprange sh tests/devroot.sh

REPO=$(dirname "$(dirname "$(readlink -f "$0")")")
D=/tmp/s4s-dev
R=$D/opt
rm -rf "$D"
mkdir -p "$D/mock" "$R/etc/shin4static/lists" "$R/var/shin4static"

cat > "$R/etc/shin4static/shin4static.conf" <<'EOF'
ISP=eth3
ISP_GW=auto
VPN1=nwg0
VPN2=nwg1
DNS_WAIT=5
EOF
printf '# VPN-сервер\n203.0.113.7\n' > "$R/etc/shin4static/lists/isp.list"
cat > "$R/etc/shin4static/lists/vpn1.list" <<'EOF'
# Работа: только через VPN
!KS0 AS13335  # офисные сервисы
!KS2 198.51.100.0/24
!KS2 vpn.example.org

# Разное
one.one.one.one
2ip.ru  # проверка IP
https://example.com/
EOF
printf '!KS1 8.8.8.8\n' > "$R/etc/shin4static/lists/vpn2.list"

cat > "$D/mock/curl" <<'EOF'
#!/bin/sh
echo '{"prefixes":["104.16.0.0/13","172.64.0.0/13","10.0.0.0/8"]}'
EOF
cat > "$D/mock/birdc" <<'EOF'
#!/bin/sh
case "$*" in
	"show status") exit 0 ;;
	"configure check") echo "Configuration OK" ;;
	configure) echo "Reconfigured" ;;
	"show protocols") printf 's4s_static_step1 Static s4s_step1 up\ns4s_kernel_step1 Kernel s4s_step1 up\n' ;;
esac
EOF
cat > "$D/mock/ip" <<'EOF'
#!/bin/sh
case "$*" in
	"route show") echo "default via 192.0.2.1 dev eth3" ;;
	"-o link show dev eth3") echo "3: eth3: <BROADCAST,UP,LOWER_UP> mtu 1500" ;;
	"-o link show dev nwg0") echo "9: nwg0: <POINTOPOINT,UP,LOWER_UP> mtu 1420" ;;
	"rule show") printf '30031:\tfrom all lookup 1031\n30032:\tfrom all lookup 1032\n30039:\tfrom all lookup 1039\n' ;;
	"route get "*) echo "${3} dev nwg0 table 1031 src 10.8.0.2" ;;
esac
EOF
cat > "$D/s4s" <<EOF
#!/bin/sh
export S4S_ROOT=$R S4S_LIB=$REPO/lib IPRANGE=${IPRANGE:-iprange} S4S_SOCK=
export CURL=$D/mock/curl BIRDC=$D/mock/birdc IP=$D/mock/ip
exec sh $REPO/bin/shin4static "\$@"
EOF
chmod +x "$D/mock/"* "$D/s4s"
echo "S4S_ROOT=$R S4S_BIN=$D/s4s"
