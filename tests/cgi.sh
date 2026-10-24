#!/bin/sh
# Tests for the web CGI: run it the way httpd does, with a stub shin4static.
#   sh tests/cgi.sh

REPO=$(dirname "$(dirname "$(readlink -f "$0")")")
CGI=$REPO/www/cgi-bin/s4s
T=$(mktemp -d /tmp/s4s-cgi.XXXXXX)
trap 'rm -rf "$T"' EXIT
FAILS=0

ok()   { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }

export S4S_ROOT=$T/opt
mkdir -p "$S4S_ROOT/etc/shin4static/lists" "$S4S_ROOT/var/shin4static"
printf 'ISP=ppp0\nVPN1=nwg0\nVPN2=\nWEB_HOSTS="my.keenetic.net"\nWEB_ALLOW="192.168.1.0/24"\nCURL_TIMEOUT=60\n' > "$S4S_ROOT/etc/shin4static/shin4static.conf"
printf '1.2.3.4\n' > "$S4S_ROOT/etc/shin4static/lists/vpn1.list"
printf '0123456789abcdef\n' > "$S4S_ROOT/var/shin4static/web.token"
cat > "$T/stub" <<'EOF'
#!/bin/sh
echo "stub $*"
[ "$1" = check ] && exit 1
exit 0
EOF
chmod +x "$T/stub"
export S4S_BIN=$T/stub
TOK=0123456789abcdef

# req METHOD QUERY [BODY] [HOST] [CLIENT]
req() {
	if [ -n "$3" ]; then
		printf '%s' "$3" | env REQUEST_METHOD="$1" QUERY_STRING="$2" CONTENT_LENGTH=${#3} HTTP_COOKIE="$COOKIE_HDR" \
			HTTP_HOST="${4:-192.168.1.1:8088}" REMOTE_ADDR="${5-192.168.1.50}" sh "$CGI"
	else
		env REQUEST_METHOD="$1" QUERY_STRING="$2" CONTENT_LENGTH=0 HTTP_COOKIE="$COOKIE_HDR" \
			HTTP_HOST="${4:-192.168.1.1:8088}" REMOTE_ADDR="${5-192.168.1.50}" sh "$CGI" < /dev/null
	fi > "$T/resp"
}
COOKIE_HDR=
result() { sed -n 's/^X-S4S-Result: \([a-z]*\).*/\1/p' "$T/resp"; }
body() { sed '1,/^\r\{0,1\}$/d' "$T/resp"; }

req GET 'a=token' '' '' '10.1.30.7'
check "guest network refused" "[ \"\$(result)\" = error ] && body | grep -q 'запрещён'"

req GET 'a=token' '' '' '127.0.0.1'
check "localhost allowed" "[ \"\$(result)\" = ok ]"

req GET 'a=token' '' '' ''
check "unknown client refused" "[ \"\$(result)\" = error ]"

req GET 'a=token'
check "token readable" "[ \"\$(body)\" = $TOK ] && [ \"\$(result)\" = ok ]"

req GET 'a=info'
check "info lists interfaces only" "body | grep -qx 'VPN1=nwg0' && ! body | grep -q 'CURL'"

req GET 'a=get&name=vpn1.list'
check "get list" "[ \"\$(body)\" = 1.2.3.4 ]"

req GET 'a=get&name=../shin4static.conf'
check "path traversal refused" "[ \"\$(result)\" = error ]"

req GET 'a=get&name=vpn1.list' '' 'evil.example.com'
check "foreign Host refused" "[ \"\$(result)\" = error ] && body | grep -q 'не разрешено'"

req GET 'a=get&name=vpn1.list' '' 'my.keenetic.net:8088'
check "allowed host name" "[ \"\$(result)\" = ok ]"

req POST 'a=save&name=vpn1.list' 'x'
check "POST without token refused" "[ \"\$(result)\" = error ] && grep -qx 1.2.3.4 '$S4S_ROOT/etc/shin4static/lists/vpn1.list'"

req POST "a=save&name=vpn1.list&t=bad" 'x'
check "POST with wrong token refused" "[ \"\$(result)\" = error ]"

req POST "a=save&name=vpn1.list&t=$TOK" "$(printf '!KS0 AS13335\r\n5.6.7.8\r\n')"
check "save ok" "[ \"\$(result)\" = ok ]"
check "save strips CR" "! grep -q \"\$(printf '\r')\" '$S4S_ROOT/etc/shin4static/lists/vpn1.list' && grep -qx '5.6.7.8' '$S4S_ROOT/etc/shin4static/lists/vpn1.list'"

req POST "a=save&name=evil.sh&t=$TOK" 'x'
check "save other file refused" "[ \"\$(result)\" = error ] && [ ! -e '$S4S_ROOT/etc/shin4static/lists/evil.sh' ]"

req GET "a=save&name=vpn1.list&t=$TOK"
check "save via GET refused" "[ \"\$(result)\" = error ]"

req POST "a=check&t=$TOK" ' '
check "check failure reported" "[ \"\$(result)\" = error ] && body | grep -q 'stub check'"

req POST "a=apply&t=$TOK" ' '
check "apply runs update" "[ \"\$(result)\" = ok ] && body | grep -q 'stub update'"

req GET 'a=why&ip=1.2.3.4;reboot'
check "why rejects junk" "[ \"\$(result)\" = error ]"

req GET 'a=why&ip=1.2.3.4'
check "why runs" "body | grep -q 'stub why 1.2.3.4'"

echo "== WEB_AUTH=router (mocked Keenetic /auth)"
# Keenetic /auth: GET -> 401 with realm and challenge; POST JSON with
# sha256(challenge + md5(login:realm:password)) -> 200 or 401; DELETE logs out.
cat > "$T/kcurl" <<EOF
#!/bin/sh
case " \$* " in
	*" -X DELETE "*) echo delete >> "$T/router.log"; exit 0 ;;
	*" --data-binary "*)
		_want=\$(printf '%s' "ABC123\$(printf '%s' 'admin:Keenetic Test:secret' | md5sum | cut -d' ' -f1)" | sha256sum | cut -d' ' -f1)
		_got=\$(cat | sed -n 's/.*"password":"\([0-9a-f]*\)".*/\1/p')
		echo "post \$_got" >> "$T/router.log"
		[ "\$_got" = "\$_want" ] && printf 200 || printf 401
		exit 0 ;;
esac
[ -e "$T/router.down" ] && exit 7
printf 'HTTP/1.1 401 Unauthorized\r\nX-NDM-Realm: Keenetic Test\r\nX-NDM-Challenge: ABC123\r\n\r\n'
EOF
chmod +x "$T/kcurl"
export CURL=$T/kcurl
printf 'WEB_AUTH=router\nWEB_USERS="admin"\nROUTER_URL=http://router\n' >> "$S4S_ROOT/etc/shin4static/shin4static.conf"
SESS=$S4S_ROOT/var/shin4static/web-sessions

req GET 'a=token'
check "no session: auth" "[ \"\$(result)\" = auth ]"

req GET 'a=get&name=vpn1.list'
check "no session: no data" "[ \"\$(result)\" = auth ] && ! body | grep -q 5.6.7.8"

req POST 'a=login' "$(printf 'admin\nwrong')"
check "wrong password refused" "[ \"\$(result)\" = error ] && body | grep -q 'неверный'"

req POST 'a=login' "$(printf 'guest\nsecret')"
check "user outside WEB_USERS refused" "[ \"\$(result)\" = error ]"

: > "$T/router.log"
req POST 'a=login' "$(printf 'admin\nsecret')"
SID=$(sed -n 's/^Set-Cookie: s4s_session=\([0-9a-f]*\);.*/\1/p' "$T/resp" | tr -d '\r')
check "router password accepted" "[ \"\$(result)\" = ok ] && [ \${#SID} = 32 ]"
check "cookie is HttpOnly and SameSite" "grep -q 'HttpOnly; SameSite=Strict' '$T/resp'"
check "router session closed" "grep -qx delete '$T/router.log'"
check "password not stored" "! grep -rq secret '$SESS'"

COOKIE_HDR="other=1; s4s_session=$SID"
req GET 'a=get&name=vpn1.list'
check "session gives access" "[ \"\$(result)\" = ok ] && body | grep -q 5.6.7.8"

COOKIE_HDR="s4s_session=0123456789abcdef0123456789abcdef"
req GET 'a=token'
check "forged session refused" "[ \"\$(result)\" = auth ]"

COOKIE_HDR="s4s_session=$SID"
touch -d '2 days ago' "$SESS/$SID"
req GET 'a=token'
check "expired session refused and removed" "[ \"\$(result)\" = auth ] && [ ! -e '$SESS/$SID' ]"

touch "$T/router.down"
req POST 'a=login' "$(printf 'admin\nsecret')"
check "router not answering reported" "[ \"\$(result)\" = error ] && body | grep -q 'роутер не ответил'"
rm -f "$T/router.down"

req POST 'a=login' "$(printf 'admin\nsecret')"
SID=$(sed -n 's/^Set-Cookie: s4s_session=\([0-9a-f]*\);.*/\1/p' "$T/resp" | tr -d '\r')
COOKIE_HDR="s4s_session=$SID"
req POST 'a=logout'
check "logout needs token" "[ \"\$(result)\" = error ] && [ -e '$SESS/$SID' ]"
req POST "a=logout&t=$TOK"
check "logout removes session" "[ \"\$(result)\" = ok ] && [ ! -e '$SESS/$SID' ] && grep -q 'Max-Age=0' '$T/resp'"

echo
if [ "$FAILS" = 0 ]; then echo "Все тесты прошли"; else echo "Провалено: $FAILS"; exit 1; fi
