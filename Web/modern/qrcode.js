"use strict";

// Self-contained QR Code encoder (ISO/IEC 18004, byte mode) so the dashboard never calls an external service.
(function (root) {
    const ECC_CODEWORDS_PER_BLOCK = {
        L: [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        M: [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
        Q: [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
        H: [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30]
    };

    const NUM_EC_BLOCKS = {
        L: [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
        M: [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
        Q: [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
        H: [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81]
    };

    const FORMAT_BITS = { L: 1, M: 0, Q: 3, H: 2 };

    const MASKS = [
        (x, y) => (x + y) % 2 === 0,
        (x, y) => y % 2 === 0,
        (x, y) => x % 3 === 0,
        (x, y) => (x + y) % 3 === 0,
        (x, y) => (Math.floor(x / 3) + Math.floor(y / 2)) % 2 === 0,
        (x, y) => ((x * y) % 2) + ((x * y) % 3) === 0,
        (x, y) => (((x * y) % 2) + ((x * y) % 3)) % 2 === 0,
        (x, y) => (((x + y) % 2) + ((x * y) % 3)) % 2 === 0
    ];

    function gfMultiply(x, y) {
        let z = 0;
        for (let i = 7; i >= 0; i--) {
            z = (z << 1) ^ ((z >>> 7) * 0x11D);
            z ^= ((y >>> i) & 1) * x;
        }
        return z;
    }

    function rsDivisor(degree) {
        const result = new Array(degree).fill(0);
        result[degree - 1] = 1;
        let rootValue = 1;
        for (let i = 0; i < degree; i++) {
            for (let j = 0; j < result.length; j++) {
                result[j] = gfMultiply(result[j], rootValue);
                if (j + 1 < result.length) result[j] ^= result[j + 1];
            }
            rootValue = gfMultiply(rootValue, 0x02);
        }
        return result;
    }

    function rsRemainder(data, divisor) {
        const result = divisor.map(() => 0);
        for (const value of data) {
            const factor = value ^ result.shift();
            result.push(0);
            divisor.forEach((coefficient, i) => { result[i] ^= gfMultiply(coefficient, factor); });
        }
        return result;
    }

    function rawDataModules(version) {
        let result = (16 * version + 128) * version + 64;
        if (version >= 2) {
            const numAlign = Math.floor(version / 7) + 2;
            result -= (25 * numAlign - 10) * numAlign - 55;
            if (version >= 7) result -= 36;
        }
        return result;
    }

    function dataCodewords(version, ecl) {
        return Math.floor(rawDataModules(version) / 8) - ECC_CODEWORDS_PER_BLOCK[ecl][version] * NUM_EC_BLOCKS[ecl][version];
    }

    function alignmentPositions(version) {
        if (version === 1) return [];
        const size = version * 4 + 17;
        const numAlign = Math.floor(version / 7) + 2;
        const step = Math.floor((version * 8 + numAlign * 3 + 5) / (numAlign * 4 - 4)) * 2;
        const result = [6];
        for (let pos = size - 7; result.length < numAlign; pos -= step) result.splice(1, 0, pos);
        return result;
    }

    function addEccAndInterleave(data, version, ecl) {
        const numBlocks = NUM_EC_BLOCKS[ecl][version];
        const eccLength = ECC_CODEWORDS_PER_BLOCK[ecl][version];
        const rawCodewords = Math.floor(rawDataModules(version) / 8);
        const numShortBlocks = numBlocks - (rawCodewords % numBlocks);
        const shortBlockLength = Math.floor(rawCodewords / numBlocks);
        const divisor = rsDivisor(eccLength);

        const blocks = [];
        for (let i = 0, offset = 0; i < numBlocks; i++) {
            const blockData = data.slice(offset, offset + shortBlockLength - eccLength + (i < numShortBlocks ? 0 : 1));
            offset += blockData.length;
            const ecc = rsRemainder(blockData, divisor);
            // Pad short blocks so every block has the same length; the pad is skipped when interleaving.
            if (i < numShortBlocks) blockData.push(0);
            blocks.push(blockData.concat(ecc));
        }

        const result = [];
        for (let i = 0; i < blocks[0].length; i++) {
            blocks.forEach((block, j) => {
                if (i !== shortBlockLength - eccLength || j >= numShortBlocks) result.push(block[i]);
            });
        }
        return result;
    }

    function penalty(modules) {
        const n = modules.length;
        let score = 0;

        for (let a = 0; a < n; a++) {
            for (const horizontal of [true, false]) {
                let run = 1;
                for (let b = 1; b < n; b++) {
                    const current = horizontal ? modules[a][b] : modules[b][a];
                    const previous = horizontal ? modules[a][b - 1] : modules[b - 1][a];
                    if (current === previous) {
                        run++;
                        if (run === 5) score += 3;
                        else if (run > 5) score++;
                    } else {
                        run = 1;
                    }
                }
            }
        }

        for (let y = 0; y < n - 1; y++) {
            for (let x = 0; x < n - 1; x++) {
                const c = modules[y][x];
                if (c === modules[y][x + 1] && c === modules[y + 1][x] && c === modules[y + 1][x + 1]) score += 3;
            }
        }

        const finderLike = [true, false, true, true, true, false, true];
        for (let a = 0; a < n; a++) {
            for (const horizontal of [true, false]) {
                const get = k => (k < 0 || k >= n) ? false : (horizontal ? modules[a][k] : modules[k][a]);
                for (let b = 0; b + 7 <= n; b++) {
                    if (!finderLike.every((value, k) => get(b + k) === value)) continue;
                    const lightBefore = [1, 2, 3, 4].every(k => !get(b - k));
                    const lightAfter = [7, 8, 9, 10].every(k => !get(b + k));
                    if (lightBefore || lightAfter) score += 40;
                }
            }
        }

        let dark = 0;
        modules.forEach(row => row.forEach(value => { if (value) dark++; }));
        const total = n * n;
        score += Math.max(0, Math.ceil(Math.abs(dark * 20 - total * 10) / total) - 1) * 10;

        return score;
    }

    function encode(text, ecl = "M") {
        if (!FORMAT_BITS.hasOwnProperty(ecl)) throw new RangeError(`Unknown error-correction level '${ecl}'.`);

        const bytes = Array.from(new TextEncoder().encode(String(text)));

        let version = 1;
        let capacityBits = 0;
        for (; version <= 40; version++) {
            capacityBits = dataCodewords(version, ecl) * 8;
            if (4 + (version <= 9 ? 8 : 16) + bytes.length * 8 <= capacityBits) break;
        }
        if (version > 40) throw new RangeError("Text is too long to fit in a QR code.");

        const bits = [];
        const pushBits = (value, length) => {
            for (let i = length - 1; i >= 0; i--) bits.push((value >>> i) & 1);
        };
        pushBits(0b0100, 4);
        pushBits(bytes.length, version <= 9 ? 8 : 16);
        bytes.forEach(value => pushBits(value, 8));
        pushBits(0, Math.min(4, capacityBits - bits.length));
        pushBits(0, (8 - (bits.length % 8)) % 8);
        for (let pad = 0xEC; bits.length < capacityBits; pad ^= 0xEC ^ 0x11) pushBits(pad, 8);

        const data = [];
        for (let i = 0; i < bits.length; i += 8) {
            data.push(bits.slice(i, i + 8).reduce((acc, bit) => (acc << 1) | bit, 0));
        }
        const codewords = addEccAndInterleave(data, version, ecl);

        const size = version * 4 + 17;
        const modules = Array.from({ length: size }, () => new Array(size).fill(false));
        const isFunction = Array.from({ length: size }, () => new Array(size).fill(false));
        const setFunction = (x, y, dark) => {
            modules[y][x] = dark;
            isFunction[y][x] = true;
        };

        for (let i = 0; i < size; i++) {
            setFunction(6, i, i % 2 === 0);
            setFunction(i, 6, i % 2 === 0);
        }

        for (const [cx, cy] of [[3, 3], [size - 4, 3], [3, size - 4]]) {
            for (let dy = -4; dy <= 4; dy++) {
                for (let dx = -4; dx <= 4; dx++) {
                    const x = cx + dx;
                    const y = cy + dy;
                    if (x < 0 || x >= size || y < 0 || y >= size) continue;
                    const distance = Math.max(Math.abs(dx), Math.abs(dy));
                    setFunction(x, y, distance !== 2 && distance !== 4);
                }
            }
        }

        const align = alignmentPositions(version);
        const last = align.length - 1;
        align.forEach((ax, i) => align.forEach((ay, j) => {
            if ((i === 0 && j === 0) || (i === 0 && j === last) || (i === last && j === 0)) return;
            for (let dy = -2; dy <= 2; dy++) {
                for (let dx = -2; dx <= 2; dx++) {
                    setFunction(ax + dx, ay + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
                }
            }
        }));

        const drawFormat = mask => {
            const formatData = (FORMAT_BITS[ecl] << 3) | mask;
            let remainder = formatData;
            for (let i = 0; i < 10; i++) remainder = (remainder << 1) ^ ((remainder >>> 9) * 0x537);
            const formatBits = ((formatData << 10) | remainder) ^ 0x5412;
            const bit = i => ((formatBits >>> i) & 1) !== 0;

            for (let i = 0; i <= 5; i++) setFunction(8, i, bit(i));
            setFunction(8, 7, bit(6));
            setFunction(8, 8, bit(7));
            setFunction(7, 8, bit(8));
            for (let i = 9; i < 15; i++) setFunction(14 - i, 8, bit(i));

            for (let i = 0; i < 8; i++) setFunction(size - 1 - i, 8, bit(i));
            for (let i = 8; i < 15; i++) setFunction(8, size - 15 + i, bit(i));
            setFunction(8, size - 8, true);
        };

        if (version >= 7) {
            let remainder = version;
            for (let i = 0; i < 12; i++) remainder = (remainder << 1) ^ ((remainder >>> 11) * 0x1F25);
            const versionBits = (version << 12) | remainder;
            for (let i = 0; i < 18; i++) {
                const dark = ((versionBits >>> i) & 1) !== 0;
                const a = size - 11 + (i % 3);
                const b = Math.floor(i / 3);
                setFunction(a, b, dark);
                setFunction(b, a, dark);
            }
        }

        drawFormat(0);

        let bitIndex = 0;
        for (let right = size - 1; right >= 1; right -= 2) {
            if (right === 6) right = 5;
            for (let vert = 0; vert < size; vert++) {
                for (let j = 0; j < 2; j++) {
                    const x = right - j;
                    const upward = ((right + 1) & 2) === 0;
                    const y = upward ? size - 1 - vert : vert;
                    if (!isFunction[y][x] && bitIndex < codewords.length * 8) {
                        modules[y][x] = ((codewords[bitIndex >>> 3] >>> (7 - (bitIndex & 7))) & 1) !== 0;
                        bitIndex++;
                    }
                }
            }
        }

        const applyMask = mask => {
            for (let y = 0; y < size; y++) {
                for (let x = 0; x < size; x++) {
                    if (!isFunction[y][x] && MASKS[mask](x, y)) modules[y][x] = !modules[y][x];
                }
            }
        };

        let bestMask = 0;
        let bestPenalty = Infinity;
        for (let mask = 0; mask < 8; mask++) {
            applyMask(mask);
            drawFormat(mask);
            const score = penalty(modules);
            if (score < bestPenalty) {
                bestPenalty = score;
                bestMask = mask;
            }
            applyMask(mask);
        }
        applyMask(bestMask);
        drawFormat(bestMask);

        return { version, size, mask: bestMask, modules };
    }

    function escapeXml(value) {
        return String(value).replace(/[&<>"']/g, ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
    }

    function toSvg(text, options = {}) {
        const { ecl = "M", border = 4, dark = "#0b1220", light = "#ffffff", title = "" } = options;
        const { size, modules } = encode(text, ecl);
        const dimension = size + border * 2;
        let path = "";
        modules.forEach((row, y) => row.forEach((on, x) => {
            if (on) path += `M${x + border} ${y + border}h1v1h-1z`;
        }));
        const label = escapeXml(title || "QR code");
        return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${dimension} ${dimension}" shape-rendering="crispEdges" role="img" aria-label="${label}"><title>${label}</title><rect width="100%" height="100%" fill="${escapeXml(light)}"/><path d="${path}" fill="${escapeXml(dark)}"/></svg>`;
    }

    root.MailboxQr = { encode, toSvg };
})(typeof window !== "undefined" ? window : globalThis);
