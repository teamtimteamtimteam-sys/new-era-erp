// scripts/lib/sql-in-list.mjs
// ════════════════════════════════════════════════════════════════════════════
// F13(MES-7b-1,2026-10-16;MES7A2-ENUM-PARSERS-STOP-AT-A-COMMENT,Tim 的裁定)· 从表镜像里读一条 `col IN ('a', 'b', …)` 的取值 ——
//   【按字符走】,一份实现,两支检查(check-enum-mirrors · check-i18n)共用。
// ════════════════════════════════════════════════════════════════════════════
// 【它替掉的那两句】`CHECK \(\s*col IN\s*\(([^)]+)\)` —— 截到【第一个】`)` 为止:
//   ① 列表中间一句 `-- 注释` 里只要出现一个 `)`,列表就被截短(check-enum-mirrors 是先截再剥注释,剥得再干净也晚了);
//   ② check-i18n 那一支根本不剥注释,于是注释里一个 `'词'` 会被当成一个取值。
//   MES-7a-2 第一稿就这么让两支检查各少数了两个流水类型,而两支都报绿。
// 【怎么走】(AGENTS.md「按字符走,认转义、认字符串、认注释、认括号深度,不认换行」)
//   · 状态机:代码 · `--` 行注释 · `/* */` 块注释(可嵌套,与 PostgreSQL 同)· `'…'` 字符串(`''` 是转义)· `"…"` 引号标识符;
//   · 先在【只剩代码】的那一份文本里找 `col IN (`(注释与字符串里的同名字不算);
//   · 再从那个 `(` 起按括号深度走到与它配对的 `)`,只在深度 1 收字符串字面量 —— 注释里的 `)` 与 `'词'` 一个都碰不到深度与取值。
// 【覆盖断言】countLiteralsOutsideComments:用【另一条路】(先把注释整段删掉、再数引号对)数同一段里的字面量个数 ——
//   两条路的数对不上,调用方退 2(量具坏了)。它不是第二份同样的状态机:它按"删注释 → 数 '...'"走,与上面按深度收值是两种走法。
// 【故障注入】readInList 的 `mode: 'old-regex'` 换回旧的那一句(只为让每一支检查自带的那几格故障能证明自己会红)。

/** 把一段 SQL 按字符切成 { code, kinds }:code 里注释被换成空格(长度不变),kinds[i] 说第 i 个字符在哪种状态里。 */
export function scanSql(src) {
    const kinds = new Array(src.length)
    let code = ''
    let i = 0
    let depthBlock = 0
    let state = 'code'   // code | line | block | str | ident
    while (i < src.length) {
        const c = src[i], n = src[i + 1]
        if (state === 'code') {
            if (c === '-' && n === '-') { state = 'line'; kinds[i] = kinds[i + 1] = 'comment'; code += '  '; i += 2; continue }
            if (c === '/' && n === '*') { state = 'block'; depthBlock = 1; kinds[i] = kinds[i + 1] = 'comment'; code += '  '; i += 2; continue }
            if (c === "'") { state = 'str'; kinds[i] = 'str'; code += c; i++; continue }
            if (c === '"') { state = 'ident'; kinds[i] = 'ident'; code += c; i++; continue }
            kinds[i] = 'code'; code += c; i++; continue
        }
        if (state === 'line') {
            if (c === '\n') { state = 'code'; kinds[i] = 'code'; code += c; i++; continue }
            kinds[i] = 'comment'; code += ' '; i++; continue
        }
        if (state === 'block') {
            if (c === '/' && n === '*') { depthBlock++; kinds[i] = kinds[i + 1] = 'comment'; code += '  '; i += 2; continue }
            if (c === '*' && n === '/') {
                depthBlock--; kinds[i] = kinds[i + 1] = 'comment'; code += '  '; i += 2
                if (depthBlock === 0) state = 'code'
                continue
            }
            kinds[i] = 'comment'; code += c === '\n' ? '\n' : ' '; i++; continue
        }
        if (state === 'str') {
            if (c === "'" && n === "'") { kinds[i] = kinds[i + 1] = 'str'; code += "''"; i += 2; continue }
            kinds[i] = 'str'; code += c; i++
            if (c === "'") state = 'code'
            continue
        }
        // ident
        if (c === '"' && n === '"') { kinds[i] = kinds[i + 1] = 'ident'; code += '""'; i += 2; continue }
        kinds[i] = 'ident'; code += c; i++
        if (c === '"') state = 'code'
    }
    return { code, kinds }
}

/** 在 code(注释已换成空格)里找第一处【代码位置上】的 `col IN (`;checkOnly 时要求它紧挨在 `CHECK (` 后面(可以有 `col IS NULL OR` 之类在中间)。
 *  返回那个 `(` 的下标,找不到 → -1。 */
function findInListOpen(scan, col, checkOnly) {
    const re = new RegExp(String.raw`\b${col}\s+IN\s*\(`, 'g')
    let m
    while ((m = re.exec(scan.code)) !== null) {
        const start = m.index
        if (scan.kinds[start] !== 'code') continue
        if (checkOnly) {
            // 往回找最近的 `CHECK (` —— 中间只许是同一个括号层里的条件(`col IS NULL OR …`)
            const before = scan.code.slice(Math.max(0, start - 400), start)
            if (!/CHECK\s*\(\s*(?:[\s\S]*?\bOR\s+)?$/.test(before)) continue
        }
        return start + m[0].length - 1
    }
    return -1
}

/** 从 `(` 起按深度走到配对的 `)`,只在深度 1 收 '…' 字面量(注释里的字符在 scan.code 里已是空格,碰不到深度)。 */
function collectLiterals(src, scan, openAt) {
    const values = []
    let depth = 0
    for (let i = openAt; i < src.length; i++) {
        const k = scan.kinds[i]
        if (k === 'comment' || k === 'ident') continue
        if (k === 'str') {
            // 一个字面量从这里开始:读到它的结束引号
            let j = i + 1, v = ''
            while (j < src.length) {
                if (src[j] === "'" && src[j + 1] === "'") { v += "'"; j += 2; continue }
                if (src[j] === "'") break
                v += src[j]; j++
            }
            if (depth === 1) values.push(v)
            i = j
            continue
        }
        const c = src[i]
        if (c === '(') depth++
        else if (c === ')') { depth--; if (depth === 0) return { values, closeAt: i } }
    }
    return { values: null, closeAt: -1 }
}

/** 旧的那一句(故障注入用;也是本文件替掉的东西):截到第一个 `)`。
 *  stripAfterCut:check-enum-mirrors 原来那一支在截完【之后】再剥 `--` 注释(于是注释里的 'ghost' 它本来就不认,截短照样截短);
 *  check-i18n 原来那几支不剥。两种原样都留着,交回报告逐格说出原来那一支到底有哪一个缺陷。 */
function oldRegex(src, col, checkOnly, stripAfterCut) {
    const m = src.match(new RegExp(checkOnly ? String.raw`CHECK \(\s*${col} IN\s*\(([^)]+)\)` : String.raw`\b${col} IN\s*\(([^)]+)\)`, 's'))
    if (!m) return null
    const body = stripAfterCut ? m[1].split('\n').map((l) => l.replace(/--.*$/, '')).join('\n') : m[1]
    return { values: [...body.matchAll(/'([^']+)'/g)].map((x) => x[1]), span: m[1] }
}

/**
 * 读 `col IN (…)` 的取值。
 * @param {string} src     表镜像的全文
 * @param {string} col     列名
 * @param {{ checkOnly?: boolean, mode?: 'chars' | 'old-regex' | 'old-regex-strip' }} [opt]
 *   checkOnly:true = 只认 `CHECK (col IN (…))`(以及 `CHECK (col IS NULL OR col IN (…))`);false = 文件里第一处代码位置上的 `col IN (…)`
 * @returns {{ values: string[], span: string }}  span = 括号里那一段原文(给覆盖断言用)
 * 找不到 / 括号不配对 → 抛错(解析不出来不是空集合)。
 */
export function readInList(src, col, opt = {}) {
    const checkOnly = opt.checkOnly ?? true
    if (opt.mode === 'old-regex' || opt.mode === 'old-regex-strip') {
        const r = oldRegex(src, col, checkOnly, opt.mode === 'old-regex-strip')
        if (!r) throw new Error(`找不到 ${checkOnly ? 'CHECK (' : ''}${col} IN (...)`)
        return r
    }
    const scan = scanSql(src)
    const openAt = findInListOpen(scan, col, checkOnly)
    if (openAt < 0) throw new Error(`找不到 ${checkOnly ? 'CHECK (' : ''}${col} IN (...)(代码位置上;注释与字符串里的不算)`)
    const { values, closeAt } = collectLiterals(src, scan, openAt)
    if (values === null) throw new Error(`${col} IN ( 的括号没有配对 —— 文件被截断了,或者解析器坏了`)
    return { values, span: src.slice(openAt + 1, closeAt) }
}

/** 覆盖断言的【另一条路】:先把注释整段删掉(块注释、行注释),再数 '…' 字面量的个数(`''` 算转义)。 */
export function countLiteralsOutsideComments(span) {
    const noBlock = span.replace(/\/\*[\s\S]*?\*\//g, ' ')
    const noLine = noBlock.split('\n').map((l) => {
        // 行注释从第一个不在字符串里的 `--` 开始 —— 这里用"引号计数为偶数"判断它在不在字符串外(一种与状态机无关的判法)
        for (let i = 0; i < l.length - 1; i++) {
            if (l[i] === '-' && l[i + 1] === '-' && ((l.slice(0, i).match(/'/g) ?? []).length % 2 === 0)) return l.slice(0, i)
        }
        return l
    }).join('\n')
    return (noLine.match(/'(?:[^']|'')*'/g) ?? []).length
}

/**
 * 每一支用它的检查【每一次运行】都跑的两格:注释里有 `)` 不许截短;注释里有 '词' 不许多出一个值。
 * 返回失败的格子(空 = 两格都过)。mode 由调用方的故障注入开关传进来 —— 换回旧的那一句,两格都必须红。
 */
export function selfCells(mode) {
    const truncate = `CREATE TABLE t (\n    kind text NOT NULL CHECK (kind IN\n        ('alpha', 'beta',\n         -- a comment that closes a bracket ) mid-list\n         'gamma', 'delta'))\n);\n`
    const ghost = `CREATE TABLE t (\n    kind text NOT NULL CHECK (kind IN\n        ('alpha', 'beta',\n         -- a comment that quotes 'ghost' mid-list\n         'gamma'))\n);\n`
    const out = []
    let got
    try { got = readInList(truncate, 'kind', { mode }).values.join(',') } catch (e) { got = `(抛错:${e.message})` }
    if (got !== 'alpha,beta,gamma,delta') out.push(`注释里的 ")" 截短了列表:读出 ${got},应当是 alpha,beta,gamma,delta`)
    try { got = readInList(ghost, 'kind', { mode }).values.join(',') } catch (e) { got = `(抛错:${e.message})` }
    if (got !== 'alpha,beta,gamma') out.push(`注释里的 'ghost' 被当成了一个值:读出 ${got},应当是 alpha,beta,gamma`)
    return out
}
