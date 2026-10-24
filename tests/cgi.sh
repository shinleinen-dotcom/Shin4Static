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
CONF=$S4S_ROOT/etc/shin4static/shin4static.conf
LISTS=$S4S_ROOT/etc/shin4static/lists
LIST=$LISTS/vpn1.list
STATE=$S4S_ROOT/var/shin4static
mkdir -p "$LISTS" "$STATE"
printf 'ISP=ppp0\nVPN1=nwg0\nVPN2=\nWEB_HOSTS="my.keenetic.net"\nWEB_ALLOW="192.168.1.0/24"   # LAN\nCURL_TIMEOUT=60\n' > "$CONF"
printf '1.2.3.4\n' > "$LIST"
printf '0123456789abcdef0123456789abcdef' > "$STATE/web.token"
# As S81shin4static-web writes it when lighttpd runs with its own password.
echo local > "$STATE/web.mode"
cat > "$T/stub" <<'EOF'
#!/bin/sh
echo "stub $*"
[ "$1" = check ] && exit 1
exit 0
EOF
chmod +x "$T/stub"
export S4S_BIN=$T/stub
TOK=0123456789abcdef0123456789abcdef

# lighttpd's mod_auth user (WEB_AUTH=local); RUSER= - not authenticated.
RUSER=admin
ORIGIN=
FETCH_SITE=
# req METHOD QUERY [BODY] [HOST] [CLIENT]
req() {
	if [ -n "$3" ]; then
		printf '%s' "$3" | env REQUEST_METHOD="$1" QUERY_STRING="$2" CONTENT_LENGTH=${#3} HTTP_COOKIE="$COOKIE_HDR" \
			HTTP_HOST="${4:-192.168.1.1:8088}" REMOTE_ADDR="${5-192.168.1.50}" REMOTE_USER="$RUSER" \
			HTTP_ORIGIN="$ORIGIN" HTTP_SEC_FETCH_SITE="$FETCH_SITE" sh "$CGI"
	else
		env REQUEST_METHOD="$1" QUERY_STRING="$2" CONTENT_LENGTH=0 HTTP_COOKIE="$COOKIE_HDR" \
			HTTP_HOST="${4:-192.168.1.1:8088}" REMOTE_ADDR="${5-192.168.1.50}" REMOTE_USER="$RUSER" \
			HTTP_ORIGIN="$ORIGIN" HTTP_SEC_FETCH_SITE="$FETCH_SITE" sh "$CGI" < /dev/null
	fi > "$T/resp"
}
COOKIE_HDR=
result() { sed -n 's/^X-S4S-Result: \([a-z]*\).*/\1/p' "$T/resp"; }
body() { sed '1,/^\r\{0,1\}$/d' "$T/resp"; }
# Version of the list as the page sends it with save.
base() { cat "$LIST" 2>/dev/null | md5sum | cut -d' ' -f1; }

req GET 'a=token' '' '' '10.1.30.7'
check "guest network refused" "[ \"\$(result)\" = error ] && body | grep -q 'запрещён'"

req GET 'a=token' '' '' '127.0.0.1'
check "localhost allowed" "[ \"\$(result)\" = ok ]"

req GET 'a=token' '' '' ''
check "unknown client refused" "[ \"\$(result)\" = error ]"

req GET 'a=token' '' '' '192.168.1.77'
check "WEB_ALLOW with a trailing comment read like sh does" "[ \"\$(result)\" = ok ]"

: > "$STATE/web.token"
req POST "a=save&name=vpn1.list&base=$(base)&t=" 'x'
check "empty token never matches" "[ \"\$(result)\" = error ] && ! grep -qx x '$LIST'"
check "empty token file regenerated" "grep -qE '^[0-9a-f]{32}\$' '$STATE/web.token'"
printf '%s' "$TOK" > "$STATE/web.token"

req GET 'a=token'
check "token readable" "[ \"\$(body)\" = $TOK ] && [ \"\$(result)\" = ok ]"

echo "== login mode comes from web.mode (what lighttpd runs), not the config"
RUSER=
req GET 'a=token'
check "local mode without lighttpd user refused" "[ \"\$(result)\" = error ] && ! body | grep -q $TOK"
RUSER=admin
rm "$STATE/web.mode"
req GET 'a=token'
check "no web.mode: refused" "[ \"\$(result)\" = error ] && ! body | grep -q $TOK"
echo router > "$STATE/web.mode"
cp "$CONF" "$T/conf.save"
printf 'WEB_AUTH=local\n' >> "$CONF"
req GET 'a=token'
check "router mode needs a session whatever WEB_AUTH says" "[ \"\$(result)\" = auth ]"
cp "$T/conf.save" "$CONF"
echo local > "$STATE/web.mode"

req GET 'a=info'
check "info lists interfaces only" "body | grep -qx 'VPN1=nwg0' && body | grep -qx 'WEB_AUTH=local' && ! body | grep -q 'CURL'"

req GET 'a=get&name=vpn1.list'
check "get list" "[ \"\$(body)\" = 1.2.3.4 ]"

req GET 'a=get&name=../shin4static.conf'
check "path traversal refused" "[ \"\$(result)\" = error ]"

req GET 'a=get&name=vpn1.list' '' 'evil.example.com'
check "foreign Host refused" "[ \"\$(result)\" = error ] && body | grep -q 'не разрешено'"

req GET 'a=get&name=vpn1.list' '' 'my.keenetic.net:8088'
check "allowed host name" "[ \"\$(result)\" = ok ]"

req POST "a=save&name=vpn1.list&base=$(base)" 'x'
check "POST without token refused" "[ \"\$(result)\" = error ] && grep -qx 1.2.3.4 '$LIST'"

req POST "a=save&name=vpn1.list&base=$(base)&t=bad" 'x'
check "POST with wrong token refused" "[ \"\$(result)\" = error ]"

echo "== requests from other sites"
ORIGIN=http://evil.example.com
req POST "a=save&name=vpn1.list&base=$(base)&t=$TOK" 'x'
check "foreign Origin refused" "[ \"\$(result)\" = error ] && body | grep -q 'чужого сайта' && grep -qx 1.2.3.4 '$LIST'"
ORIGIN=
FETCH_SITE=cross-site
req POST "a=apply&t=$TOK" ' '
check "Sec-Fetch-Site cross-site refused" "[ \"\$(result)\" = error ] && ! body | grep -q 'stub update'"
FETCH_SITE=same-origin
ORIGIN=http://192.168.1.1:8088

req POST "a=save&name=vpn1.list&base=$(base)&t=$TOK" "$(printf '!KS0 AS13335\r\n5.6.7.8\r\n')"
check "save ok (own Origin)" "[ \"\$(result)\" = ok ]"
check "save strips CR" "! grep -q \"\$(printf '\r')\" '$LIST' && grep -qx '5.6.7.8' '$LIST'"
check "no temp files left" "[ \"\$(ls -A '$LISTS')\" = vpn1.list ]"

echo "== save checks the version the page loaded"
_old=$(base)
printf '9.9.9.9\n' > "$LIST"
req POST "a=save&name=vpn1.list&base=$_old&t=$TOK" 'x'
check "changed on the router: refused" "[ \"\$(result)\" = error ] && body | grep -q 'изменён на роутере' && grep -qx 9.9.9.9 '$LIST'"
req POST "a=save&name=vpn1.list&t=$TOK" 'x'
check "save without base refused" "[ \"\$(result)\" = error ] && grep -qx 9.9.9.9 '$LIST'"
mkdir "$LISTS/.save.lock"
req POST "a=save&name=vpn1.list&base=$(base)&t=$TOK" 'x'
check "parallel save refused" "[ \"\$(result)\" = error ] && grep -qx 9.9.9.9 '$LIST'"
check "lock of the other save kept" "[ -d '$LISTS/.save.lock' ]"
rmdir "$LISTS/.save.lock"
req POST "a=save&name=vpn2.list&base=$(printf '' | md5sum | cut -d' ' -f1)&t=$TOK" '7.7.7.7'
check "new file: base of empty text" "[ \"\$(result)\" = ok ] && grep -qx 7.7.7.7 '$LISTS/vpn2.list'"
rm -f "$LISTS/vpn2.list"

req POST "a=save&name=evil.sh&base=$(base)&t=$TOK" 'x'
check "save other file refused" "[ \"\$(result)\" = error ] && [ ! -e '$LISTS/evil.sh' ]"

req GET "a=save&name=vpn1.list&base=$(base)&t=$TOK"
check "save via GET refused" "[ \"\$(result)\" = error ]"

req POST "a=check&t=$TOK" ' '
check "check failure reported" "[ \"\$(result)\" = error ] && body | grep -q 'stub check'"

req POST "a=apply&t=$TOK" ' '
check "apply runs update" "[ \"\$(result)\" = ok ] && body | grep -q 'stub update'"

req GET 'a=why&ip=1.2.3.4;reboot'
check "why rejects junk" "[ \"\$(result)\" = error ]"

req GET 'a=why&ip=1.2.3.4'
check "why runs" "body | grep -q 'stub why 1.2.3.4'"

# lighttpd starts the CGI with no PATH at all; the child must still get one.
printf '#!/bin/sh\necho "PATH=$PATH"\n' > "$T/pathstub"
chmod +x "$T/pathstub"
env -i REQUEST_METHOD=GET QUERY_STRING='a=status' REMOTE_ADDR=192.168.1.50 REMOTE_USER=admin \
	S4S_ROOT="$S4S_ROOT" S4S_BIN="$T/pathstub" /bin/sh "$CGI" > "$T/resp"
check "child gets exported PATH with /opt/bin" "body | grep -q '^PATH=/opt/bin:'"

echo "== WEB_AUTH=router (mocked Keenetic /auth)"
# Keenetic /auth: GET -> 401 with realm and challenge; POST JSON with
# sha256(challenge + md5(login:realm:password)) -> 200 or 401; DELETE logs out.
cat > "$T/kcurl" <<EOF
#!/bin/sh
case " \$* " in
	*" -X DELETE "*) echo delete >> "$T/router.log"; exit 0 ;;
	*" --data-binary "*)
		_want=\$(printf '%s' "ABC123\$(printf '%s' 'admin:Keenetic Test:secret' | md5sum | cut -d' ' -f1)" | sha256sum | cut -d' ' -f1)
		_got=\$(cat)
		echo "post \$_got" >> "$T/router.log"
		_got=\$(printf '%s' "\$_got" | sed -n 's/.*"password":"\([0-9a-f]*\)".*/\1/p')
		[ "\$_got" = "\$_want" ] && printf 200 || printf 401
		exit 0 ;;
esac
[ -e "$T/router.down" ] && exit 7
printf 'HTTP/1.1 401 Unauthorized\r\nX-NDM-Realm: Keenetic Test\r\nX-NDM-Challenge: ABC123\r\n\r\n'
EOF
chmod +x "$T/kcurl"
export CURL=$T/kcurl
printf 'WEB_AUTH=router   # пароль роутера\nWEB_USERS="admin"\nROUTER_URL=http://router\n' >> "$CONF"
echo router > "$STATE/web.mode"
RUSER=
SESS=$STATE/web-sessions
FAILS_FILE=$STATE/web-login.fails

# login USER PASSWORD: challenge, then the answer the page computes.
login() {
	req GET 'a=challenge'
	ID=$(body | sed -n 1p)
	_realm=$(body | sed -n 2p)
	_chal=$(body | sed -n 3p)
	_hash=$(printf '%s' "$_chal$(printf '%s' "$1:$_realm:$2" | md5sum | cut -d' ' -f1)" | sha256sum | cut -d' ' -f1)
	req POST 'a=login' "$(printf '%s\n%s\n%s' "$1" "$ID" "$_hash")"
}
sid() { sed -n 's/^Set-Cookie: s4s_session=\([0-9a-f]*\);.*/\1/p' "$T/resp" | tr -d '\r'; }

req GET 'a=token'
check "no session: auth" "[ \"\$(result)\" = auth ]"

req GET 'a=get&name=vpn1.list'
check "no session: no data" "[ \"\$(result)\" = auth ] && ! body | grep -q 9.9.9.9"

req GET 'a=challenge'
check "challenge gives id, realm, challenge" "[ \"\$(result)\" = ok ] && [ \"\$(body | sed -n 2p)\" = 'Keenetic Test' ] && [ \"\$(body | sed -n 3p)\" = ABC123 ] && [ \"\$(body | sed -n 1p | wc -c)\" = 33 ]"

login admin wrong
check "wrong password refused" "[ \"\$(result)\" = error ] && body | grep -q 'неверный'"

login guest secret
check "user outside WEB_USERS refused" "[ \"\$(result)\" = error ]"

: > "$T/router.log"
login admin secret
SID=$(sid)
check "router password accepted" "[ \"\$(result)\" = ok ] && [ \${#SID} = 32 ]"
check "password never sent, only the hash" "! grep -q secret '$T/router.log' && grep -q '\"password\":\"[0-9a-f]\{64\}\"' '$T/router.log'"
check "session id is never empty" "! grep -q 's4s_session=;' '$T/resp'"
check "cookie is HttpOnly and SameSite" "grep -q 'HttpOnly; SameSite=Strict' '$T/resp'"
check "router session closed" "grep -qx delete '$T/router.log'"
check "password not stored" "! grep -rq secret '$SESS'"
check "failure counter reset" "[ ! -e '$FAILS_FILE' ]"

req POST 'a=login' "$(printf 'admin\n%s\n%s' "$ID" "$_hash")"
check "challenge used only once" "[ \"\$(result)\" = error ] && body | grep -q 'устарел'"

COOKIE_HDR="other=1; s4s_session=$SID"
req GET 'a=get&name=vpn1.list'
check "session gives access" "[ \"\$(result)\" = ok ] && body | grep -q 9.9.9.9"

COOKIE_HDR="s4s_session=0123456789abcdef0123456789abcdef"
req GET 'a=token'
check "forged session refused" "[ \"\$(result)\" = auth ]"

COOKIE_HDR="s4s_session=$SID"
touch -d '2 days ago' "$SESS/$SID"
req GET 'a=token'
check "expired session refused and removed" "[ \"\$(result)\" = auth ] && [ ! -e '$SESS/$SID' ]"
COOKIE_HDR=

req GET 'a=challenge'
ID=$(body | sed -n 1p)
touch -d '10 minutes ago' "$STATE/web-login/$ID"
req POST 'a=login' "$(printf 'admin\n%s\n%s' "$ID" "$_hash")"
check "old challenge refused" "[ \"\$(result)\" = error ] && body | grep -q 'устарел'"

ORIGIN=http://evil.example.com
login admin secret
check "login from another site refused" "[ \"\$(result)\" = error ] && body | grep -q 'чужого сайта'"
ORIGIN=http://192.168.1.1:8088

mkdir "$STATE/web-login.lock"
login admin secret
check "one login attempt at a time" "[ \"\$(result)\" = error ] && body | grep -q 'другая попытка'"
rmdir "$STATE/web-login.lock"

echo "== guessing: after 3 wrong passwords attempts wait"
rm -f "$FAILS_FILE"
login admin a; login admin b; login admin c
login admin secret
check "right password waits after 3 failures" "[ \"\$(result)\" = error ] && body | grep -q 'подождите'"
touch -d '5 minutes ago' "$FAILS_FILE"
login admin secret
check "accepted after the wait" "[ \"\$(result)\" = ok ]"

touch "$T/router.down"
req GET 'a=challenge'
check "router not answering reported" "[ \"\$(result)\" = error ] && body | grep -q 'роутер не ответил'"
rm -f "$T/router.down"

login admin secret
SID=$(sid)
COOKIE_HDR="s4s_session=$SID"
req POST 'a=logout'
check "logout needs token" "[ \"\$(result)\" = error ] && [ -e '$SESS/$SID' ]"
req POST "a=logout&t=$TOK"
check "logout removes session" "[ \"\$(result)\" = ok ] && [ ! -e '$SESS/$SID' ] && grep -q 'Max-Age=0' '$T/resp'"

echo
if [ "$FAILS" = 0 ]; then echo "Все тесты прошли"; else echo "Провалено: $FAILS"; exit 1; fi
