#!/bin/sh
# Shin4Static uninstaller. Settings and lists are kept unless --purge is given.
# The system bird, /opt/etc/bird.conf and Bird4Static are not touched.

PREFIX=/opt
export PATH=$PREFIX/bin:$PREFIX/sbin:${PATH:-/sbin:/bin:/usr/sbin:/usr/bin}

[ -x "$PREFIX/etc/init.d/S81shin4static-web" ] && "$PREFIX/etc/init.d/S81shin4static-web" stop
# Works with a broken config too: defaults and the numbers applied last time.
if [ -x "$PREFIX/bin/shin4static" ]; then
	"$PREFIX/bin/shin4static" daemon stop
	"$PREFIX/bin/shin4static" rules stop
	"$PREFIX/bin/shin4static" flush
fi
# BIRD left without its control socket.
_pid=$(cat "$PREFIX/var/run/shin4static-bird.pid" 2>/dev/null)
[ -n "$_pid" ] && kill "$_pid" 2>/dev/null
rm -f "$PREFIX/var/run/shin4static-bird.pid" "$PREFIX/var/run/shin4static-bird.ctl"


rm -f "$PREFIX/etc/init.d/S02shin4static" "$PREFIX/etc/init.d/S81shin4static-web" \
	"$PREFIX/etc/cron.hourly/shin4static" "$PREFIX/bin/shin4static"
rm -rf "$PREFIX/share/shin4static" "$PREFIX/var/shin4static" "$PREFIX/etc/shin4static/gen"

if [ "$1" = --purge ]; then
	rm -rf "$PREFIX/etc/shin4static"
	echo "Удалены настройки и списки"
else
	echo "Настройки и списки оставлены в $PREFIX/etc/shin4static (удалить: $0 --purge)"
fi
echo "Пакеты bird2, ip-full, iprange, lighttpd и др. не удалялись: ими могут пользоваться другие программы."
