// MD5 and SHA-256 of a string (UTF-8), hex. WebCrypto is not available on a
// plain-HTTP page at a LAN address, and it has no MD5 at all; both are needed
// for the router's login answer and for the version of a saved list.
"use strict";

(function (root) {
	function utf8(s) {
		return new TextEncoder().encode(s);
	}

	function hex(words, little) {
		let out = "";
		for (const w of words) {
			for (let i = 0; i < 4; i++) {
				const b = little ? (w >>> (8 * i)) & 255 : (w >>> (24 - 8 * i)) & 255;
				out += (b < 16 ? "0" : "") + b.toString(16);
			}
		}
		return out;
	}

	// Message padded to 64-byte blocks with its bit length, as 32-bit words.
	function blocks(bytes, little) {
		const n = ((bytes.length + 8) >> 6) + 1;
		const w = new Uint32Array(n * 16);
		for (let i = 0; i < bytes.length; i++) {
			w[i >> 2] |= bytes[i] << (little ? 8 * (i & 3) : 24 - 8 * (i & 3));
		}
		const i = bytes.length;
		w[i >> 2] |= 0x80 << (little ? 8 * (i & 3) : 24 - 8 * (i & 3));
		const bits = bytes.length * 8;
		const hi = Math.floor(bits / 0x100000000);
		if (little) {
			w[n * 16 - 2] = bits >>> 0;
			w[n * 16 - 1] = hi;
		} else {
			w[n * 16 - 2] = hi;
			w[n * 16 - 1] = bits >>> 0;
		}
		return w;
	}

	const rotl = (x, c) => (x << c) | (x >>> (32 - c));
	const rotr = (x, c) => (x >>> c) | (x << (32 - c));

	const MD5_S = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21];
	const MD5_K = Array.from({ length: 64 }, (_, i) => Math.floor(Math.abs(Math.sin(i + 1)) * 0x100000000) >>> 0);

	function md5(s) {
		const w = blocks(utf8(s), true);
		let a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
		for (let j = 0; j < w.length; j += 16) {
			let a = a0, b = b0, c = c0, d = d0;
			for (let i = 0; i < 64; i++) {
				let f, g;
				if (i < 16) { f = (b & c) | (~b & d); g = i; }
				else if (i < 32) { f = (d & b) | (~d & c); g = (5 * i + 1) & 15; }
				else if (i < 48) { f = b ^ c ^ d; g = (3 * i + 5) & 15; }
				else { f = c ^ (b | ~d); g = (7 * i) & 15; }
				const t = d;
				d = c;
				c = b;
				b = (b + rotl((a + f + MD5_K[i] + w[j + g]) | 0, MD5_S[(i >> 4) * 4 + (i & 3)])) | 0;
				a = t;
			}
			a0 = (a0 + a) | 0; b0 = (b0 + b) | 0; c0 = (c0 + c) | 0; d0 = (d0 + d) | 0;
		}
		return hex([a0, b0, c0, d0], true);
	}

	const SHA_K = [
		0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
		0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
		0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
		0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
		0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
		0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
		0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
		0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
	];

	function sha256(s) {
		const w = blocks(utf8(s), false);
		const h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
		const m = new Array(64);
		for (let j = 0; j < w.length; j += 16) {
			for (let i = 0; i < 64; i++) {
				if (i < 16) m[i] = w[j + i] | 0;
				else {
					const s0 = rotr(m[i - 15], 7) ^ rotr(m[i - 15], 18) ^ (m[i - 15] >>> 3);
					const s1 = rotr(m[i - 2], 17) ^ rotr(m[i - 2], 19) ^ (m[i - 2] >>> 10);
					m[i] = (m[i - 16] + s0 + m[i - 7] + s1) | 0;
				}
			}
			let [a, b, c, d, e, f, g, k] = h;
			for (let i = 0; i < 64; i++) {
				const t1 = (k + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + SHA_K[i] + m[i]) | 0;
				const t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) | 0;
				k = g; g = f; f = e; e = (d + t1) | 0;
				d = c; c = b; b = a; a = (t1 + t2) | 0;
			}
			const v = [a, b, c, d, e, f, g, k];
			for (let i = 0; i < 8; i++) h[i] = (h[i] + v[i]) | 0;
		}
		return hex(h, false);
	}

	const api = { md5, sha256 };
	if (typeof module !== "undefined") module.exports = api;
	else root.S4SHash = api;
})(this);
