#!/bin/sh
# Shin4Static installer. Re-run it to update: settings and lists are kept.

SRC=$(dirname "$(readlink -f "$0")")
PREFIX=/opt
SHARE=$PREFIX/share/shin4static
ETC=$PREFIX/etc/shin4static
CONF=$ETC/shin4static.conf

say() { printf '%s\n' "$*"; }
die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

ask() {
	printf '%s ' "$1"
	read -r REPLY
}

pick_iface() {
	_prompt=$1
	_allow_empty=$2
	while :; do
		ask "$_prompt"
		[ -z "$REPLY" ] && [ "$_allow_empty" = 1 ] && return 0
		case "$REPLY" in
			*[!A-Za-z0-9_.-]*|'') say "Недопустимое имя интерфейса." ; continue ;;
		esac
		ip link show "$REPLY" >/dev/null 2>&1 && return 0
		say "Интерфейса $REPLY нет. Выберите из списка выше."
	done
}

[ -d "$PREFIX" ] && [ -x "$PREFIX/bin/opkg" ] || die "нужен Entware в $PREFIX"

[ -e "$PREFIX/etc/init.d/S02bird-table" ] &&
	say "Найден Bird4Static: он продолжит работать как раньше, Shin4Static его не трогает."

say "Ставлю пакеты..."
"$PREFIX/bin/opkg" update >/dev/null
# ip-full: the firmware ip does not accept routing table ids above 255.
"$PREFIX/bin/opkg" install bird2 bird2c ip-full curl ca-certificates iprange cron ||
	die "не удалось установить пакеты"
[ -x "$PREFIX/sbin/ip" ] || die "нет $PREFIX/sbin/ip из пакета ip-full"

say "Копирую файлы в $SHARE..."
mkdir -p "$SHARE/sbin" "$ETC/lists" "$ETC/gen" "$PREFIX/var/shin4static"
rm -rf "$SHARE/bin" "$SHARE/lib"
cp -r "$SRC/bin" "$SRC/lib" "$SHARE/"
chmod +x "$SHARE/bin/shin4static"
ln -sf "$SHARE/bin/shin4static" "$PREFIX/bin/shin4static"

# Own renamed copies of bird/birdc: "killall bird", S70bird and removal of the
# bird2 package (e.g. by Bird4Static's uninstall) do not affect them.
for _b in bird birdc; do
	_src=$(command -v "$_b" 2>/dev/null)
	[ -n "$_src" ] || _src=$PREFIX/sbin/$_b
	[ -x "$_src" ] || die "не найден $_b из пакета bird2"
	cp "$_src" "$SHARE/sbin/.s4s-$_b.new" && mv "$SHARE/sbin/.s4s-$_b.new" "$SHARE/sbin/s4s-$_b" ||
		die "не удалось скопировать $_b"
	chmod +x "$SHARE/sbin/s4s-$_b"
done
cp "$SRC/etc/bird.conf" "$ETC/bird.conf"

for _l in isp vpn1 vpn2; do
	[ -f "$ETC/lists/$_l.list" ] || cp "$SRC/examples/$_l.list" "$ETC/lists/$_l.list"
done

if [ ! -f "$CONF" ]; then
	say ""
	say "Интерфейсы с адресами:"
	ip -o -4 addr show | awk '{ print "  " $2, $4 }'
	pick_iface "Интерфейс провайдера (например ppp0 или eth3):" 0
	_isp=$REPLY
	_gw=
	case "$_isp" in
		ppp*) ;;
		*) _gw=auto; say "Для $_isp маршруты пойдут через шлюз провайдера (ISP_GW=auto)." ;;
	esac
	pick_iface "Интерфейс VPN1 (например nwg0):" 0
	_vpn1=$REPLY
	pick_iface "Интерфейс VPN2 (Enter — без второго VPN):" 1
	_vpn2=$REPLY
	sed -e "s/^ISP=.*/ISP=$_isp/" -e "s/^ISP_GW=.*/ISP_GW=$_gw/" \
		-e "s/^VPN1=.*/VPN1=$_vpn1/" -e "s/^VPN2=.*/VPN2=$_vpn2/" \
		"$SRC/etc/shin4static.conf.example" > "$CONF"
	say "Настройки записаны в $CONF"
fi

rm -rf "$SHARE/www"
cp -r "$SRC/www" "$SHARE/"
chmod +x "$SHARE/www/cgi-bin/s4s"
cp "$SRC/etc/init.d/S81shin4static-web" "$PREFIX/etc/init.d/S81shin4static-web"
chmod +x "$PREFIX/etc/init.d/S81shin4static-web"

# set_conf NAME VALUE: replace or append a line in shin4static.conf.
set_conf() {
	if grep -q "^$1=" "$CONF"; then
		sed -i "s|^$1=.*|$1=$2|" "$CONF"
	else
		echo "$1=$2" >> "$CONF"
	fi
}

# Web interface: own lighttpd instance, password in htdigest format.
AUTH=$ETC/web.htdigest
if [ ! -s "$AUTH" ]; then
	ask "Включить веб-интерфейс (lighttpd)? Y/n"
	if [ "$REPLY" != n ]; then
		_had_lighttpd=$("$PREFIX/bin/opkg" list-installed | grep -c '^lighttpd ')
		"$PREFIX/bin/opkg" install lighttpd lighttpd-mod-auth lighttpd-mod-authn_file lighttpd-mod-cgi ||
			die "не удалось установить lighttpd"
		# We only need the binary: do not start the default lighttpd at boot
		# if it was installed just for us.
		if [ "$_had_lighttpd" = 0 ] && [ -f "$PREFIX/etc/init.d/S80lighttpd" ]; then
			"$PREFIX/etc/init.d/S80lighttpd" stop >/dev/null 2>&1
			sed -i 's/^ENABLED=yes/ENABLED=no/' "$PREFIX/etc/init.d/S80lighttpd"
			say "Стандартный lighttpd (S80lighttpd) выключен: Shin4Static запускает свой."
		fi
		_lan=$(ip -o -4 addr show br0 2>/dev/null | awk '{ print $4; exit }')
		[ -n "$_lan" ] || die "не найден адрес br0"
		ask "Порт (Enter — 8088):"
		_port=${REPLY:-8088}
		case "$_port" in ''|*[!0-9]*) die "порт должен быть числом" ;; esac
		while :; do
			printf 'Пароль для входа (логин admin): '
			stty -echo 2>/dev/null; read -r _pw; stty echo 2>/dev/null; echo
			[ -n "$_pw" ] && break
			say "Пароль не может быть пустым."
		done
		_md5=$(printf '%s' "admin:Shin4Static:$_pw" | md5sum | cut -d' ' -f1)
		umask 077
		echo "admin:Shin4Static:$_md5" > "$AUTH"
		umask 022
		set_conf WEB_LISTEN "${_lan%/*}:$_port"
		set_conf WEB_ALLOW "\"$_lan\""
		say "Веб-интерфейс: http://${_lan%/*}:$_port/ (логин admin). Пароль сменить — удалите $AUTH и запустите install.sh."
	fi
fi

cp "$SRC/etc/init.d/S02shin4static" "$PREFIX/etc/init.d/S02shin4static"
cp "$SRC/etc/cron.hourly/shin4static" "$PREFIX/etc/cron.hourly/shin4static"
chmod +x "$PREFIX/etc/init.d/S02shin4static" "$PREFIX/etc/cron.hourly/shin4static"

say "Запуск и первое обновление маршрутов..."
"$PREFIX/bin/shin4static" daemon stop
"$PREFIX/bin/shin4static" rules start
"$PREFIX/bin/shin4static" daemon start
"$PREFIX/bin/shin4static" update
"$PREFIX/etc/init.d/S10cron" restart >/dev/null 2>&1
"$PREFIX/etc/init.d/S81shin4static-web" restart

say ""
say "Готово. Списки: $ETC/lists/  Проверка: shin4static check  Состояние: shin4static status"
