"use strict";

const M = window.S4SModel;
const H = window.S4SHash;
const API = "cgi-bin/s4s";
const FILES = ["isp.list", "vpn1.list", "vpn2.list"];
const PRIMARY = { "isp.list": 0, "vpn1.list": 1, "vpn2.list": 2 };

const st = {
	token: "",
	info: {},
	current: "vpn1.list",
	mode: "list",
	saved: {},     // file -> text as on the router
	blocks: {},    // file -> blocks (list mode)
	raw: {},       // file -> text (text mode)
	lines: {},     // file -> line map of the last saved text
	filter: "",
};

const $ = (id) => document.getElementById(id);
const listEl = $("listview");
const textEl = $("text");
const gutterEl = $("gutter");
const outEl = $("out");

// Tiny DOM builder: h("div", { class: "x", onclick }, child, ...)
function h(tag, props, ...kids) {
	const el = document.createElement(tag);
	for (const [k, v] of Object.entries(props || {})) {
		if (v === undefined || v === null || v === false) continue;
		if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
		else if (k === "class") el.className = v;
		else if (k in el && k !== "list") el[k] = v;
		else el.setAttribute(k, v === true ? "" : v);
	}
	for (const kid of kids.flat()) if (kid !== null && kid !== undefined && kid !== false) el.append(kid);
	return el;
}

// ---------- API ----------

// Thrown when the session is missing or expired; the login form is shown.
class AuthNeeded extends Error {}

async function call(action, { name, body, params } = {}) {
	const q = new URLSearchParams({ a: action, ...(params || {}) });
	if (name) q.set("name", name);
	const post = ["save", "check", "apply", "login", "logout"].includes(action);
	if (post && action !== "login") q.set("t", st.token);
	const res = await fetch(`${API}?${q}`, {
		method: post ? "POST" : "GET",
		body: post ? (body ?? " ") : undefined,
		headers: post ? { "Content-Type": "text/plain; charset=utf-8" } : undefined,
		cache: "no-store",
		credentials: "same-origin",
	});
	const text = await res.text();
	const result = res.headers.get("X-S4S-Result");
	if (result === "auth") {
		showLogin();
		throw new AuthNeeded();
	}
	return { ok: res.ok && result === "ok", text };
}

// ---------- login (WEB_AUTH=router) ----------

function showLogin(message) {
	$("login").hidden = false;
	$("loginerr").hidden = !message;
	$("loginerr").textContent = message || "";
	$("loginpass").value = "";
	$("loginpass").focus();
}

$("loginform").onsubmit = async (e) => {
	e.preventDefault();
	const user = $("loginuser").value.trim();
	const pass = $("loginpass").value;
	const btn = e.target.querySelector("button");
	btn.disabled = true;
	try {
		// The router's own scheme: only sha256(challenge + md5(login:realm:password))
		// leaves the browser, never the password.
		const c = await call("challenge");
		if (!c.ok) {
			showLogin(c.text.trim());
			return;
		}
		const [id, realm, challenge] = c.text.split("\n");
		const answer = H.sha256(challenge + H.md5(`${user}:${realm}:${pass}`));
		const r = await call("login", { body: `${user}\n${id}\n${answer}` });
		if (!r.ok) {
			showLogin(r.text.trim());
			return;
		}
		$("login").hidden = true;
		// After an expired session keep the unsaved edits: only renew the token.
		if (loaded().length) {
			st.token = (await call("token")).text.trim();
		} else {
			await busy(load);
		}
	} catch (err) {
		if (!(err instanceof AuthNeeded)) showLogin(String(err));
	} finally {
		btn.disabled = false;
	}
};

$("logout").onclick = () =>
	busy(async () => {
		if (loaded().some(dirty) && !confirm("Есть несохранённые изменения. Выйти без сохранения?")) return;
		await call("logout");
		location.reload();
	});

// ---------- file state ----------

const loaded = () => FILES.filter((f) => f in st.saved);

function currentText(file) {
	if (st.mode === "text" && file === st.current) return textEl.value;
	if (file in st.raw) return st.raw[file];
	return M.serialize(st.blocks[file]).text;
}

const dirty = (file) => M.normalize(currentText(file)) !== M.normalize(st.saved[file]);

function vpnName(n) {
	const ifn = st.info["VPN" + n];
	return ifn ? `VPN${n} (${ifn})` : `VPN${n}`;
}

// Reserve choices for the current file: configured VPNs except its own exit.
function reserveOptions() {
	const own = PRIMARY[st.current];
	const out = [];
	for (const n of [1, 2]) if (n !== own && st.info["VPN" + n]) out.push(n);
	return out;
}

function entryProblem(e) {
	if (e.rawTag) return `неизвестная метка ${e.rawTag}`;
	if (e.fb && e.fb === PRIMARY[st.current]) return "резерв совпадает с основным выходом";
	if (e.fb && !st.info["VPN" + e.fb]) return `VPN${e.fb} не настроен`;
	return M.classify(e.value).err || "";
}

// ---------- rendering ----------

function renderTabs() {
	const nav = $("tabs");
	nav.replaceChildren(
		...loaded().map((f) =>
			h("button", {
				type: "button",
				role: "tab",
				class: dirty(f) ? "dirty" : "",
				"aria-selected": String(f === st.current),
				onclick: () => switchFile(f),
			}, f),
		),
	);
	$("save").disabled = !loaded().some(dirty);
}

function matches(b, e) {
	const q = st.filter.toLowerCase();
	if (!q) return true;
	return (e && (e.value.toLowerCase().includes(q) || e.note.toLowerCase().includes(q))) || b.comment.toLowerCase().includes(q);
}

function renderList() {
	const blocks = st.blocks[st.current];
	const shown = blocks.filter((b) => !st.filter || matches(b) || b.entries.some((e) => matches(b, e)));
	listEl.replaceChildren(...shown.map((b) => renderBlock(b, blocks)));
	if (!shown.length) listEl.append(h("p", { class: "empty" }, st.filter ? "Ничего не найдено" : "Список пуст"));
	renderSelbar();
	renderTabs();
}

function ksState(entries) {
	const on = entries.filter((e) => e.ks).length;
	return { checked: on > 0 && on === entries.length, indeterminate: on > 0 && on < entries.length };
}

function fbState(entries) {
	const set = new Set(entries.map((e) => e.fb));
	return set.size === 1 ? String([...set][0]) : "mixed";
}

function reserveSelect(value, onchange, withMixed) {
	const opts = [h("option", { value: "0" }, "резерва нет")];
	for (const n of reserveOptions()) opts.push(h("option", { value: String(n) }, vpnName(n)));
	if (withMixed && value === "mixed") opts.push(h("option", { value: "mixed", disabled: true }, "разные"));
	if (value !== "mixed" && !opts.some((o) => o.value === value)) opts.push(h("option", { value }, `VPN${value}?`));
	const sel = h("select", { class: "reserve", "aria-label": "Резерв", onchange }, opts);
	sel.value = value;
	return sel;
}

function renderBlock(b, blocks) {
	const idx = blocks.indexOf(b);
	const entries = b.entries;
	const ks = ksState(entries);

	const blockKs = h("input", {
		type: "checkbox",
		title: "Kill switch для всего блока",
		disabled: !entries.length,
		onchange: (ev) => {
			entries.forEach((e) => (e.ks = ev.target.checked));
			changed();
		},
	});
	blockKs.checked = ks.checked;
	blockKs.indeterminate = ks.indeterminate;

	const head = h("div", { class: "bhead" },
		h("button", {
			type: "button",
			class: "fold",
			"aria-expanded": String(!b.collapsed),
			title: b.collapsed ? "Развернуть" : "Свернуть",
			onclick: () => { b.collapsed = !b.collapsed; renderList(); },
		}, b.collapsed ? "▸" : "▾"),
		h("textarea", {
			class: "bcomment",
			rows: Math.max(1, b.comment.split("\n").length),
			placeholder: "Комментарий к блоку",
			value: b.comment,
			oninput: (ev) => {
				b.comment = ev.target.value;
				ev.target.rows = Math.max(1, b.comment.split("\n").length);
				changed(false);
			},
		}),
		h("span", { class: "count" }, `${entries.length}`),
		h("label", { class: "ks" }, blockKs, "KS"),
		entries.length ? reserveSelect(fbState(entries), (ev) => {
			entries.forEach((e) => (e.fb = Number(ev.target.value)));
			changed();
		}, true) : null,
		h("span", { class: "bbtns" },
			h("button", { type: "button", title: "Выше", disabled: idx === 0, onclick: () => moveBlock(b, -1) }, "↑"),
			h("button", { type: "button", title: "Ниже", disabled: idx === blocks.length - 1, onclick: () => moveBlock(b, 1) }, "↓"),
			h("button", { type: "button", class: "danger", title: "Удалить блок", onclick: () => deleteBlock(b) }, "✕"),
		),
	);

	const body = b.collapsed ? null : h("div", { class: "bbody" },
		entries.filter((e) => matches(b, e)).map((e) => renderEntry(b, e)),
		st.filter ? null : addRow(b),
	);

	return h("div", { class: "block", "data-block": b.id }, head, body);
}

function renderEntry(b, e) {
	const problem = entryProblem(e);
	const kind = M.classify(e.value).kind;

	const sel = h("input", {
		type: "checkbox",
		class: "sel",
		"aria-label": "Выбрать",
		onchange: (ev) => { e.sel = ev.target.checked; row.classList.toggle("selected", e.sel); renderSelbar(); },
	});
	sel.checked = e.sel;

	const ks = h("input", {
		type: "checkbox",
		onchange: (ev) => { e.ks = ev.target.checked; changed(); },
	});
	ks.checked = e.ks;

	const badge = h("span", { class: "badge" + (problem ? " bad" : ""), title: problem }, problem ? "!" : kind || "");

	const value = h("input", {
		class: "value",
		value: e.value,
		spellcheck: false,
		"aria-label": "Запись",
		oninput: (ev) => {
			e.value = ev.target.value;
			const p = entryProblem(e);
			badge.className = "badge" + (p ? " bad" : "");
			badge.title = p;
			badge.textContent = p ? "!" : M.classify(e.value).kind || "";
			row.classList.toggle("invalid", !!p);
			changed(false);
		},
	});

	const row = h("div", { class: "entry" + (e.sel ? " selected" : "") + (problem ? " invalid" : ""), "data-entry": e.id },
		sel,
		h("span", { class: "vwrap" }, value, badge),
		h("label", { class: "ks", title: "Kill switch: при отказе выхода — не через провайдера" }, ks, "KS"),
		reserveSelect(String(e.fb), (ev) => { e.fb = Number(ev.target.value); changed(); }),
		h("input", {
			class: "note",
			value: e.note,
			placeholder: "заметка",
			"aria-label": "Заметка",
			oninput: (ev) => { e.note = ev.target.value; changed(false); },
		}),
		h("button", { type: "button", class: "del", title: "Удалить запись", onclick: () => {
			b.entries.splice(b.entries.indexOf(e), 1);
			changed();
		} }, "✕"),
	);
	return row;
}

function addRow(b) {
	const input = h("input", {
		class: "add",
		placeholder: "+ IP, подсеть, домен или AS — Enter. Можно вставить много строк",
		"aria-label": "Добавить запись",
		onkeydown: (ev) => {
			if (ev.key === "Enter" && input.value.trim()) {
				ev.preventDefault();
				addEntries(b, input.value);
			}
		},
		onpaste: (ev) => {
			const text = ev.clipboardData.getData("text");
			if (text.includes("\n")) {
				ev.preventDefault();
				addEntries(b, text);
			}
		},
	});
	return h("div", { class: "addrow" }, input);
}

function addEntries(b, text) {
	for (const line of text.replace(/\r/g, "").split("\n")) {
		if (!line.trim() || /^[#;]/.test(line.trim())) continue;
		b.entries.push(M.parseEntry(line));
	}
	changed();
	const again = listEl.querySelector(`[data-block="${b.id}"] .add`);
	if (again) again.focus();
}

function moveBlock(b, d) {
	const blocks = st.blocks[st.current];
	const i = blocks.indexOf(b);
	blocks.splice(i, 1);
	blocks.splice(i + d, 0, b);
	changed();
}

function deleteBlock(b) {
	const blocks = st.blocks[st.current];
	if (b.entries.length && !confirm(`Удалить блок и ${b.entries.length} записей?`)) return;
	blocks.splice(blocks.indexOf(b), 1);
	if (!blocks.length) blocks.push(M.newBlock());
	changed();
}

// ---------- selection ----------

const selected = () => st.blocks[st.current].flatMap((b) => b.entries.filter((e) => e.sel));

function renderSelbar() {
	if (st.mode !== "list") {
		$("selbar").hidden = true;
		return;
	}
	const n = selected().length;
	$("selbar").hidden = n === 0;
	if (!n) return;
	$("selcount").textContent = `Выбрано: ${n}`;
	const blocks = st.blocks[st.current];
	$("selmove").replaceChildren(
		h("option", { value: "" }, "Переместить в…"),
		...blocks.map((b, i) => h("option", { value: String(b.id) }, (b.comment.split("\n")[0] || `Блок ${i + 1}`).slice(0, 40))),
	);
}

function takeSelected() {
	const out = [];
	for (const b of st.blocks[st.current]) {
		out.push(...b.entries.filter((e) => e.sel));
		b.entries = b.entries.filter((e) => !e.sel);
	}
	out.forEach((e) => (e.sel = false));
	return out;
}

$("selnew").onclick = () => {
	const nb = M.newBlock();
	nb.entries = takeSelected();
	st.blocks[st.current].push(nb);
	changed();
	const c = listEl.querySelector(`[data-block="${nb.id}"] .bcomment`);
	if (c) { c.scrollIntoView({ block: "center" }); c.focus(); }
};
$("selmove").onchange = (ev) => {
	const target = st.blocks[st.current].find((b) => String(b.id) === ev.target.value);
	if (!target) return;
	const moving = takeSelected();
	target.entries.push(...moving);
	changed();
};
$("selks").onclick = () => { selected().forEach((e) => (e.ks = true)); changed(); };
$("selnoks").onclick = () => { selected().forEach((e) => (e.ks = false)); changed(); };
$("seldel").onclick = () => {
	const n = selected().length;
	if (!confirm(`Удалить ${n} записей?`)) return;
	takeSelected();
	changed();
};
$("selclear").onclick = () => { selected().forEach((e) => (e.sel = false)); renderList(); };

// ---------- modes ----------

// rerender=false keeps focus while typing; only tab markers are refreshed.
function changed(rerender = true) {
	if (rerender) renderList();
	else renderTabs();
}

function renderGutter() {
	const n = textEl.value.split("\n").length;
	let s = "";
	for (let i = 1; i <= n; i++) s += i + "\n";
	gutterEl.textContent = s;
	gutterEl.scrollTop = textEl.scrollTop;
}

function setMode(mode) {
	const f = st.current;
	if (mode === st.mode) return;
	if (mode === "text") {
		textEl.value = M.serialize(st.blocks[f]).text;
	} else {
		st.blocks[f] = M.parseText(textEl.value);
		delete st.raw[f];
	}
	st.mode = mode;
	showMode();
}

function showMode() {
	const list = st.mode === "list";
	$("listview").hidden = !list;
	$("textview").hidden = list;
	$("filter").hidden = !list;
	$("addblock").hidden = !list;
	$("viewlist").setAttribute("aria-pressed", String(list));
	$("viewtext").setAttribute("aria-pressed", String(!list));
	if (list) renderList();
	else {
		renderGutter();
		renderTabs();
		renderSelbar();
	}
}

function switchFile(file, line) {
	if (st.mode === "text") st.raw[st.current] = textEl.value;
	st.current = file;
	if (st.mode === "text") {
		textEl.value = st.raw[file] ?? M.serialize(st.blocks[file]).text;
		delete st.raw[file];
	} else if (file in st.raw) {
		st.blocks[file] = M.parseText(st.raw[file]);
		delete st.raw[file];
	}
	showMode();
	if (line) gotoLine(line);
}

function gotoLine(line) {
	if (st.mode === "text") {
		const lines = textEl.value.split("\n");
		let start = 0;
		for (let i = 0; i < line - 1 && i < lines.length; i++) start += lines[i].length + 1;
		textEl.focus();
		textEl.setSelectionRange(start, start + (lines[line - 1] ?? "").length);
		const lh = parseFloat(getComputedStyle(textEl).lineHeight) || 21;
		textEl.scrollTop = Math.max(0, (line - 4) * lh);
		renderGutter();
		return;
	}
	const ref = (st.lines[st.current] || {})[line];
	if (!ref) return;
	const b = st.blocks[st.current].find((x) => x.id === ref.block);
	if (b && b.collapsed) { b.collapsed = false; renderList(); }
	const el = listEl.querySelector(ref.entry ? `[data-entry="${ref.entry}"]` : `[data-block="${ref.block}"]`);
	if (!el) return;
	el.scrollIntoView({ block: "center" });
	el.classList.remove("flash");
	void el.offsetWidth;
	el.classList.add("flash");
	const input = el.querySelector(ref.entry ? ".value" : ".bcomment");
	if (input) input.focus();
}

// ---------- output ----------

function show(title, text, ok) {
	$("outtitle").textContent = title;
	outEl.replaceChildren();
	for (const line of text.replace(/\n+$/, "").split("\n")) {
		const div = h("div", { class: /^Ошибка/.test(line) ? "error" : /^Предупреждение/.test(line) ? "warn" : "" });
		const re = /\b((?:isp|vpn1|vpn2)\.list):(\d+)/g;
		let last = 0;
		let m;
		while ((m = re.exec(line))) {
			const [file, num] = [m[1], Number(m[2])];
			div.append(line.slice(last, m.index), h("a", { onclick: () => switchFile(file, num) }, m[0]));
			last = m.index + m[0].length;
		}
		div.append(line.slice(last));
		outEl.append(div);
	}
	if (ok !== undefined) outEl.append(h("div", { class: ok ? "okline" : "error" }, ok ? "— готово" : "— есть ошибки"));
}

async function busy(fn) {
	const buttons = document.querySelectorAll("header button, #why button");
	buttons.forEach((b) => (b.disabled = true));
	$("busy").hidden = false;
	try {
		await fn();
	} catch (e) {
		if (!(e instanceof AuthNeeded)) show("Ошибка связи", String(e), false);
	} finally {
		$("busy").hidden = true;
		buttons.forEach((b) => (b.disabled = false));
		renderTabs();
	}
}

// ---------- save / run ----------

async function saveAll() {
	if (st.mode === "text") st.raw[st.current] = textEl.value;
	for (const f of loaded()) {
		if (!dirty(f)) continue;
		let text;
		text = f in st.raw ? st.raw[f] : M.serialize(st.blocks[f]).text;
		// base: the version this page loaded; the router refuses the save if
		// the file was changed since (another tab, SSH).
		const r = await call("save", { name: f, body: text, params: { base: H.md5(st.saved[f]) } });
		if (!r.ok) {
			show("Сохранение", r.text, false);
			return false;
		}
		st.saved[f] = text;
	}
	if (st.mode === "text") delete st.raw[st.current];
	return true;
}

async function run(action, title) {
	if (!(await saveAll())) return;
	// The list stays editable while the router works: keep what was changed
	// meanwhile.
	const before = Object.fromEntries(loaded().map((f) => [f, currentText(f)]));
	const r = await call(action);
	// Line numbers in messages refer to the files as saved: rebuild from them.
	if (st.mode === "list") {
		for (const f of loaded()) {
			if (currentText(f) !== before[f]) continue;
			st.blocks[f] = M.parseText(st.saved[f]);
			st.lines[f] = st.blocks[f].lineMap;
		}
		renderList();
	}
	show(title, r.text, r.ok);
}

async function load() {
	const t = await call("token");
	if (!t.ok) {
		show("Нет доступа", t.text, false);
		return;
	}
	st.token = t.text.trim();
	const info = await call("info");
	for (const line of info.text.split("\n")) {
		const [k, ...v] = line.split("=");
		if (k) st.info[k.trim()] = v.join("=").trim();
	}
	$("logout").hidden = st.info.WEB_AUTH !== "router";
	for (const f of FILES) {
		if (f === "vpn2.list" && !st.info.VPN2) continue;
		const r = await call("get", { name: f });
		if (!r.ok) continue;
		st.saved[f] = r.text;
		st.blocks[f] = M.parseText(r.text);
		st.lines[f] = st.blocks[f].lineMap;
	}
	if (!(st.current in st.saved)) st.current = loaded()[0];
	showMode();
	const s = await call("status");
	show("Состояние", s.text);
}

// ---------- events ----------

$("viewlist").onclick = () => setMode("list");
$("viewtext").onclick = () => setMode("text");
$("filter").oninput = (ev) => { st.filter = ev.target.value.trim(); renderList(); };
$("addblock").onclick = () => {
	const nb = M.newBlock();
	st.blocks[st.current].push(nb);
	changed();
	const c = listEl.querySelector(`[data-block="${nb.id}"] .bcomment`);
	if (c) { c.scrollIntoView({ block: "center" }); c.focus(); }
};

textEl.addEventListener("input", () => { renderTabs(); renderGutter(); });
textEl.addEventListener("scroll", () => (gutterEl.scrollTop = textEl.scrollTop));

const saveAction = () => busy(async () => {
	if (await saveAll()) show("Сохранение", "Сохранено. Чтобы маршруты обновились, нажмите «Применить».", true);
});
document.addEventListener("keydown", (e) => {
	if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "s") {
		e.preventDefault();
		saveAction();
	}
});
window.addEventListener("beforeunload", (e) => {
	if (loaded().some(dirty)) e.preventDefault();
});

$("save").onclick = saveAction;
$("check").onclick = () => busy(() => run("check", "Проверка"));
$("apply").onclick = () => busy(() => run("apply", "Применение"));
$("status").onclick = () => busy(async () => show("Состояние", (await call("status")).text));
$("why").onsubmit = (e) => {
	e.preventDefault();
	const ip = $("whyip").value.trim();
	busy(async () => {
		const r = await call("why", { params: { ip } });
		show(`Куда идёт ${ip}`, r.text, r.ok);
	});
};

busy(load);
