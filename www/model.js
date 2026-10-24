// Shin4Static list file <-> blocks of entries.
//
// File format (unchanged, read by the generator):
//   # block comment, one or more lines
//   !KS0 AS13335  # entry note
//   example.com
//                 <- blank line ends a block
// A comment line after entries starts a new block.
"use strict";

(function (root) {
	let uid = 0;
	const nid = () => ++uid;

	function newBlock(comment = "") {
		return { id: nid(), comment, collapsed: false, entries: [] };
	}

	function newEntry(value = "") {
		return { id: nid(), value, note: "", ks: false, fb: 0, rawTag: "", sel: false };
	}

	function parseEntry(line) {
		const e = newEntry();
		const m = line.match(/^(.*?)[ \t]+[#;][ \t]?(.*)$/);
		if (m) {
			line = m[1];
			e.note = m[2].trim();
		}
		line = line.trim();
		if (line.startsWith("!")) {
			const sp = line.search(/\s/);
			const tag = sp < 0 ? line : line.slice(0, sp);
			line = sp < 0 ? "" : line.slice(sp).trim();
			const t = tag.toUpperCase();
			let mm;
			if ((mm = t.match(/^!KS(\d)$/))) {
				e.ks = true;
				e.fb = Number(mm[1]);
			} else if ((mm = t.match(/^!FB([1-9])$/))) {
				e.fb = Number(mm[1]);
			} else {
				e.rawTag = tag;
			}
		}
		e.value = line;
		return e;
	}

	// Blocks from text; blocks.lineMap[n] = { block, entry } for source line n.
	function parseText(text) {
		const blocks = [];
		const lineMap = {};
		let cur = null;
		let n = 0;
		for (const raw of text.replace(/\r/g, "").split("\n")) {
			n++;
			const line = raw.trim();
			if (line === "") {
				cur = null;
				continue;
			}
			if (/^[#;]/.test(line)) {
				if (!cur || cur.entries.length) {
					cur = newBlock();
					blocks.push(cur);
				}
				const c = line.replace(/^[#;][ \t]?/, "");
				cur.comment += (cur.comment ? "\n" : "") + c;
				lineMap[n] = { block: cur.id };
				continue;
			}
			if (!cur) {
				cur = newBlock();
				blocks.push(cur);
			}
			const e = parseEntry(line);
			cur.entries.push(e);
			lineMap[n] = { block: cur.id, entry: e.id };
		}
		if (!blocks.length) blocks.push(newBlock());
		blocks.lineMap = lineMap;
		return blocks;
	}

	function tagOf(e) {
		if (e.rawTag) return e.rawTag;
		if (e.ks) return "!KS" + e.fb;
		if (e.fb) return "!FB" + e.fb;
		return "";
	}

	function entryLine(e) {
		const tag = tagOf(e);
		const note = e.note.trim();
		return (tag ? tag + " " : "") + e.value.trim() + (note ? "  # " + note : "");
	}

	// Returns { text, lines } where lines[n] = { block, entry } for line n (1-based).
	function serialize(blocks) {
		const out = [];
		const lines = {};
		const used = blocks.filter((b) => b.comment.trim() || b.entries.some((e) => e.value.trim() || e.rawTag));
		used.forEach((b, i) => {
			if (i) out.push("");
			if (b.comment.trim()) {
				for (const c of b.comment.replace(/\s+$/, "").split("\n")) {
					out.push(c.trim() ? "# " + c.trimEnd() : "#");
					lines[out.length] = { block: b.id };
				}
			}
			for (const e of b.entries) {
				if (!e.value.trim() && !e.rawTag) continue;
				out.push(entryLine(e));
				lines[out.length] = { block: b.id, entry: e.id };
			}
		});
		return { text: out.length ? out.join("\n") + "\n" : "", lines };
	}

	function normalize(text) {
		return serialize(parseText(text)).text;
	}

	function ipok(s) {
		const p = s.split(".");
		return p.length === 4 && p.every((x) => /^\d{1,3}$/.test(x) && Number(x) <= 255);
	}

	// Entry kind for the badge, or { err } — mirrors lib/parse.awk.
	function classify(v) {
		v = v.trim();
		if (!v) return { err: "пустая запись" };
		if (/^as\d+$/i.test(v)) return { kind: "AS" };
		let m = v.match(/^([\d.]+)\s*-\s*([\d.]+)$/);
		if (m) return ipok(m[1]) && ipok(m[2]) ? { kind: "диапазон" } : { err: "неверный диапазон" };
		m = v.match(/^([\d.]+)\/(\d+)$/);
		if (m) return ipok(m[1]) && Number(m[2]) <= 32 ? { kind: "подсеть" } : { err: "неверная подсеть" };
		if (/^[\d.]+$/.test(v)) return ipok(v) ? { kind: "IP" } : { err: "неверный IPv4" };
		if (/:\/\//.test(v)) return { err: "это URL: нужен только домен" };
		if (/^\*/.test(v)) return { err: "маски *. не поддерживаются" };
		if (/\s/.test(v)) return { err: "одна запись на строку" };
		if (/^([a-z0-9_]([a-z0-9_-]*[a-z0-9_])?\.)+[a-z]([a-z0-9-]*[a-z0-9])?\.?$/i.test(v)) return { kind: "домен" };
		return { err: "не IP, не подсеть, не домен и не AS" };
	}

	const api = { newBlock, newEntry, parseEntry, parseText, serialize, normalize, tagOf, classify };
	if (typeof module !== "undefined") module.exports = api;
	else root.S4SModel = api;
})(this);
