// node tests/model.test.js
"use strict";
const assert = require("assert");
const M = require("../www/model.js");

let fails = 0;
function t(name, fn) {
	try {
		fn();
		console.log("ok   " + name);
	} catch (e) {
		fails++;
		console.log("FAIL " + name + "\n     " + e.message.split("\n").join("\n     "));
	}
}

const sample = [
	"# Работа",
	"# второй строкой",
	"!KS0 AS555842  # офис",
	"!ks2 10.1.0.0/16",
	"example.com",
	"",
	"",
	"# Стриминг",
	"!FB2 1.2.3.4",
	"; другой комментарий",
	"5.6.7.8 ; заметка",
	"!XX 9.9.9.9",
	"",
].join("\r\n");

t("blocks and comments", () => {
	const b = M.parseText(sample);
	assert.deepStrictEqual(b.map((x) => x.comment), ["Работа\nвторой строкой", "Стриминг", "другой комментарий"]);
	assert.deepStrictEqual(b.map((x) => x.entries.length), [3, 1, 2]);
});

t("tags to checkbox state", () => {
	const [w, s, o] = M.parseText(sample);
	assert.deepStrictEqual([w.entries[0].ks, w.entries[0].fb, w.entries[0].note], [true, 0, "офис"]);
	assert.deepStrictEqual([w.entries[1].ks, w.entries[1].fb], [true, 2]);
	assert.deepStrictEqual([w.entries[2].ks, w.entries[2].fb], [false, 0]);
	assert.deepStrictEqual([s.entries[0].ks, s.entries[0].fb], [false, 2]);
	assert.strictEqual(o.entries[1].rawTag, "!XX");
	assert.strictEqual(o.entries[0].note, "заметка");
});

t("serialize normal form", () => {
	assert.strictEqual(M.serialize(M.parseText(sample)).text, [
		"# Работа",
		"# второй строкой",
		"!KS0 AS555842  # офис",
		"!KS2 10.1.0.0/16",
		"example.com",
		"",
		"# Стриминг",
		"!FB2 1.2.3.4",
		"",
		"# другой комментарий",
		"5.6.7.8  # заметка",
		"!XX 9.9.9.9",
		"",
	].join("\n"));
});

t("round trip is stable", () => {
	const once = M.normalize(sample);
	assert.strictEqual(M.normalize(once), once);
});

t("line map points to entries", () => {
	const b = M.parseText(sample);
	const { lines } = M.serialize(b);
	assert.strictEqual(lines[3].entry, b[0].entries[0].id);
	assert.strictEqual(lines[8].entry, b[1].entries[0].id);
	assert.strictEqual(lines[10].entry, undefined);
	assert.strictEqual(lines[10].block, b[2].id);
});

t("source line map survives extra blank lines", () => {
	const b = M.parseText(sample);
	assert.strictEqual(b.lineMap[3].entry, b[0].entries[0].id);
	assert.strictEqual(b.lineMap[9].entry, b[1].entries[0].id);
	assert.strictEqual(b.lineMap[10].entry, undefined);
	assert.strictEqual(b.lineMap[12].entry, b[2].entries[1].id);
	assert.strictEqual(b.lineMap[6], undefined);
});

t("checkbox state to tags", () => {
	const e = M.newEntry("x.com");
	const tags = [[false, 0, ""], [true, 0, "!KS0"], [true, 2, "!KS2"], [false, 1, "!FB1"]].map(([ks, fb, want]) => {
		e.ks = ks;
		e.fb = fb;
		return M.tagOf(e) === want;
	});
	assert.deepStrictEqual(tags, [true, true, true, true]);
});

t("empty blocks and entries are dropped", () => {
	const b = [M.newBlock(), M.newBlock("заголовок")];
	b[0].entries.push(M.newEntry("   "));
	assert.strictEqual(M.serialize(b).text, "# заголовок\n");
	assert.strictEqual(M.serialize([M.newBlock()]).text, "");
});

t("classify", () => {
	const k = (v) => M.classify(v).kind || "ERR";
	assert.deepStrictEqual(
		["as13335", "1.2.3.4", "1.2.3.0/24", "1.2.3.4 - 1.2.3.9", "rezka.ag", "xn--p1ai.xn--p1ai", "300.1.1.1", "https://a.b", "*.a.com", "a b", "1.2.3.0/33", "localhost"].map(k),
		["AS", "IP", "подсеть", "диапазон", "домен", "домен", "ERR", "ERR", "ERR", "ERR", "ERR", "ERR"],
	);
});

console.log(fails ? `\nПровалено: ${fails}` : "\nВсе тесты прошли");
process.exitCode = fails ? 1 : 0;
