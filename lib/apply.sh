# Shin4Static: installing generated files and reloading our BIRD instance.

bird_running() {
	s4s_birdc show status >/dev/null 2>&1
}

# Start our BIRD instance if it is not running.
daemon_start() {
	bird_running && return 0
	[ -x "$BIRD" ] || die "нет $BIRD — запустите install.sh ещё раз"
	for _f in step1.routes step2.routes ks.routes; do
		[ -f "$S4S_GEN/$_f" ] || : > "$S4S_GEN/$_f"
	done
	[ -f "$S4S_GEN/shin4static.conf" ] || write_bird_include "$S4S_GEN"
	mkdir -p "$(dirname "$S4S_SOCK")" "$(dirname "$S4S_PIDFILE")"
	"$BIRD" -c "$S4S_BIRD_CONF" -s "$S4S_SOCK" -P "$S4S_PIDFILE" || die "BIRD не запустился, см. системный журнал (s4s-bird)"
	info "BIRD Shin4Static запущен"
}

# Stop it. Routes stay in the kernel (persist), so the kill switch holds.
daemon_stop() {
	if bird_running; then
		s4s_birdc down >/dev/null 2>&1
	elif [ -f "$S4S_PIDFILE" ]; then
		kill "$(cat "$S4S_PIDFILE")" 2>/dev/null
	fi
	rm -f "$S4S_PIDFILE"
}

# Move changed files from $1 to $S4S_GEN; prints the names of changed files.
install_generated() {
	for _f in shin4static.conf step1.routes step2.routes ks.routes; do
		if ! cmp -s "$1/$_f" "$S4S_GEN/$_f"; then
			[ -f "$S4S_GEN/$_f" ] && cp "$S4S_GEN/$_f" "$S4S_GEN/$_f.prev"
			mv "$1/$_f" "$S4S_GEN/$_f"
			echo "$_f"
		fi
	done
}

rollback_generated() {
	for _f in $1; do
		if [ -f "$S4S_GEN/$_f.prev" ]; then
			mv "$S4S_GEN/$_f.prev" "$S4S_GEN/$_f"
		else
			rm -f "$S4S_GEN/$_f"
		fi
	done
}

apply_generated() {
	_changed=$(install_generated "$1")
	if [ -z "$_changed" ]; then
		info "маршруты не изменились"
		return 0
	fi
	info "изменены: $(echo $_changed)"

	if ! bird_running; then
		warn "BIRD Shin4Static не запущен — маршруты применятся при его запуске (/opt/etc/init.d/S02shin4static start)"
		return 0
	fi
	_check=$(s4s_birdc configure check 2>&1)
	if ! printf '%s\n' "$_check" | grep -q 'Configuration OK'; then
		rollback_generated "$_changed"
		err "BIRD не принял новую конфигурацию, вернул прежнюю: $(printf '%s\n' "$_check" | tail -1)"
		return 1
	fi
	_res=$(s4s_birdc configure 2>&1)
	if printf '%s\n' "$_res" | grep -qi 'reconfigur'; then
		info "BIRD перечитал конфигурацию"
	else
		err "birdc configure: $(printf '%s\n' "$_res" | tail -1)"
		return 1
	fi
}
