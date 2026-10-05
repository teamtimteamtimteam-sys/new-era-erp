// scripts/lib/blank-comments.mjs
// 把 // 与 /* */ 注释涂成空格(换行留着,行号不变;字符串原样留着)。
// ★ 注释会污染将来对它自己的计数(AGENTS.md · CONFIRM-1 / ALERT-1):凡是"按字符数一遍"的那条路,数之前先涂。
// 原先住在 check-date-format.mjs;DATE-PICK-1 让 check-date-data-paths 的字符那条路也用它,于是搬到这里只留一份。
export function blankComments(src) {
    let out = ''
    let i = 0, inS = null, inLine = false, inBlock = false
    while (i < src.length) {
        const c = src[i], d = src[i + 1]
        if (inLine) { if (c === '\n') { inLine = false; out += c } else out += ' '; i++; continue }
        if (inBlock) { if (c === '*' && d === '/') { inBlock = false; out += '  '; i += 2 } else { out += (c === '\n' ? c : ' '); i++ } continue }
        if (inS) { if (c === '\\') { out += '  '; i += 2; continue } if (c === inS) inS = null; out += c; i++; continue }
        if (c === '/' && d === '/') { inLine = true; out += '  '; i += 2; continue }
        if (c === '/' && d === '*') { inBlock = true; out += '  '; i += 2; continue }
        if (c === '"' || c === "'" || c === '`') { inS = c; out += c; i++; continue }
        out += c; i++
    }
    return out
}
