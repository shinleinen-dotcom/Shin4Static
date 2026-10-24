#!/bin/bash
# End-to-end test of the web part: real lighttpd started by the real
# S81shin4static-web against a temporary root. Requests go through bash's
# /dev/tcp, so curl is not needed.
#   LIGHTTPD=/path/to/lighttpd LIGHTTPD_MODULES=/path/to/modules bash tests/web.sh

REPO=$(dirname "$(dirname "$(readlink -f "$0")")")
T=$(mktemp -d /tmp/s4s-web.XXXXXX)
export S4S_ROOT=$T/opt
R=$S4S_ROOT
INIT=$REPO/etc/init.d/S81shin4static-web
PORT=18088
URL=http://127.0.0.1:$PORT
FAILS=0
trap 'sh "$INIT" stop >/dev/null 2>&1; rm -rf "$T"' EXIT

ok()   { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

mkdir -p "$R/sbin" "$R/etc/shin4static/lists" "$R/share/shin4static" "$R/var/shin4static"
cat > "$R/sbin/lighttpd" <<EOF
#!/bin/sh
exec env LD_LIBRARY_PATH="${LIGHTTPD_LIBS:-}" "${LIGHTTPD:-/usr/sbin/lighttpd}" -m "${LIGHTTPD_MODULES:-/usr/lib/lighttpd}" "\$@"
EOF
chmod +x "$R/sbin/lighttpd"

cp -r "$REPO/www" "$R/share/shin4static/www"
# The CGI must see the test root: wrap it.
mv "$R/share/shin4static/www/cgi-bin/s4s" "$R/share/shin4static/www/cgi-bin/s4s.real"
cat > "$R/share/shin4static/www/cgi-bin/s4s" <<EOF
#!/bin/sh
S4S_ROOT=$R S4S_BIN=$T/stub exec sh $R/share/shin4static/www/cgi-bin/s4s.real
EOF
printf '#!/bin/sh\necho "stub $*"\n' > "$T/stub"
chmod +x "$T/stub"

printf 'ISP=ppp0\nVPN1=nwg0\nVPN2=\nWEB_LISTEN=127.0.0.1:%s\nWEB_ALLOW="127.0.0.0/8"\n' "$PORT" > "$R/etc/shin4static/shin4static.conf"
printf '1.2.3.4\n' > "$R/etc/shin4static/lists/vpn1.list"
# Same htdigest line as install.sh writes.
printf 'admin:Shin4Static:%s\n' "$(printf '%s' 'admin:Shin4Static:secret' | md5sum | cut -d' ' -f1)" > "$R/etc/shin4static/web.htdigest"

sh "$INIT" start > "$T/start.out" 2>&1
cat "$T/start.out"
sleep 1
check "started" "sh '$INIT' status | grep -q 'запущен (pid'"
check "renamed copy runs" "[ -x '$R/share/shin4static/sbin/s4s-lighttpd' ]"

# http METHOD PATH [USER:PASS] [BODY] -> $T/status, $T/headers, $T/body
http() {
	local auth=""
	[ -n "$3" ] && auth="Authorization: Basic $(printf '%s' "$3" | base64)"$'\r\n'
	exec 3<>"/dev/tcp/127.0.0.1/$PORT" || return 1
	printf '%s %s HTTP/1.0\r\nHost: 127.0.0.1:%s\r\n%sContent-Type: text/plain\r\nContent-Length: %s\r\n\r\n%s' \
		"$1" "$2" "$PORT" "$auth" "${#4}" "$4" >&3
	cat <&3 > "$T/resp"
	exec 3<&-
	head -1 "$T/resp" | awk '{ print $2 }' > "$T/status"
	sed -n '1,/^\r$/p' "$T/resp" > "$T/headers"
	sed '1,/^\r$/d' "$T/resp" > "$T/body"
}
st() { cat "$T/status"; }

http GET /
check "no password: 401" "[ \"\$(st)\" = 401 ]"
http GET / admin:bad
check "wrong password: 401" "[ \"\$(st)\" = 401 ]"
http GET / admin:secret
check "page with password" "[ \"\$(st)\" = 200 ] && grep -q 'Shin4Static' '$T/body'"
check "server version hidden" "! grep -qi '^server: lighttpd/' '$T/headers'"
http GET /app.js admin:secret
check "js mime type" "grep -qi '^content-type: text/javascript' '$T/headers'"
http GET '/cgi-bin/s4s?a=get&name=vpn1.list' admin:secret
check "cgi runs" "[ \"\$(st)\" = 200 ] && grep -qx 1.2.3.4 '$T/body'"
http GET '/cgi-bin/s4s?a=token' admin:secret
TOK=$(cat "$T/body")
check "token" "[ \${#TOK} = 32 ]"
http POST "/cgi-bin/s4s?a=save&name=vpn1.list&t=$TOK" admin:secret '!KS0 5.6.7.8'
check "save through lighttpd" "grep -qx '!KS0 5.6.7.8' '$R/etc/shin4static/lists/vpn1.list'"
http GET /cgi-bin/ admin:secret
check "no directory listing" "! grep -qi 'index of' '$T/body'"

sh "$INIT" stop
sleep 1
check "stopped" "! sh '$INIT' status | grep -q 'запущен (pid'"

echo
if [ "$FAILS" = 0 ]; then echo "Все тесты прошли"; else echo "Провалено: $FAILS"; exit 1; fi
