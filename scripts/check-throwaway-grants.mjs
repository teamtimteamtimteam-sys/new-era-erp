#!/usr/bin/env node
// ════════════════════════════════════════════════════════════════════════════
// U1-B(2026-10-05)· GHOST-GRANTS 的闸 —— 「一次性账号的授权只有一种造法」
// ════════════════════════════════════════════════════════════════════════════
// 【它守的那一句】(Tim:UNBLOCK-1 Q23 + MES-0 Q1)
//   **没有任何一支脚本能造出一条认不到归属的、指向 admin(或任何 is_system 角色)的授权。**
//   U1-B 之前约三十支探针 / 普查 / 冒烟各自手写"查 admin 角色 → POST 授权",于是线上一次次长出
//   真的 admin 授权、持有人是一个 @test.local 账号。现在授权一律经 scripts/ephemeral.mjs 的
//   mintThrowaway:默认授一个一次性的 probe-* 角色,真角色只在显式要求时授,而 is_system 一律拒。
//   本闸拦的是【绕过它】的写法 —— 下一支新脚本照着旧探针抄一段,当场红。
//
// 【判据】在 scripts/ 下每一个 .mjs / .js(递归)里,剥掉注释之后:
//   (a) 一次对授权表的写入 —— 指向授权表 REST 路径的 POST(裸集合路径一律算,带查询串的看紧跟着的
//       method 是不是 POST)、supabase-js 的 .from(授权表).insert/upsert、或 set_user_roles 这支 RPC;
//       以及自授标记那个函数的任何一次调用 —— 全都只许出现在 ephemeral.mjs 里;
//   (b) 一次按 `code=eq.admin` 的角色查找 —— 同上,只许在 ephemeral.mjs 里(那里也没有:它按调用方给的码查)。
//   并且 (c) ephemeral.mjs 里的 mintThrowaway 存在、并且带着【不受任何注入开关影响】的 is_system 拒绝。
//
// 【覆盖率本身是一条断言】(AGENTS.md「★★★ 覆盖率本身必须是一条断言」)
//   扫描器自己的递归遍历数一遍文件,另一条与它无关的路(`find`)再数一遍,两边的集合对不上就红,
//   并点名差在哪几个文件。剥注释的那一层也要说"我瞎了":任何一个文件剥完停在字符串 / 模板 / 注释里
//   (解析器丢了位置),就红 —— 否则那个文件后半截的授权写法它看不见,还报干净。
//   另外印出 mintThrowaway 的调用点数,并断言 > 0(0 个调用点 = 没有人在用那一种造法,或者解析器瞎了)。
//
// 【故障注入】(AGENTS.md「A verdict that reports but does not enforce is not a gate」)
//   --inject=<scripts/下的相对路径>  往那个文件的文本末尾(只在内存里)补回旧写法:一次自授标记调用 +
//                                    一次按 admin 码的角色查找 + 一次授权 POST —— 必须红,并点名那个文件;
//   --inject=all                     对每一个已改造的文件(有 mintThrowaway 调用点的)逐个做上一格,
//                                    每个文件一行;全部都红才退 0;
//   --inject=blind                   让扫描器的遍历跳过一个文件 —— 覆盖率断言必须红;
//   --inject=refusal-removed         在内存里把 ephemeral.mjs 的 is_system 拒绝删掉 —— 必须红。
//   注入补在文件【末尾】是故意的:剥注释那一层要是在中途丢了位置,补进去的代码会被当成字符串吞掉,
//   于是那一格不红 —— 不红的注入是信息(AGENTS.md「一格没有咬人的注入」),它会让 --inject=all 退 1。
//
// 退出码:0 = 干净(或 --inject=all 每一格都红了);1 = 有违例 / 覆盖率对不上 / 拒绝不在 / 注入没咬人;
//         2 = 用法错(不认识的注入、路径不在 scripts/ 下)。
// ════════════════════════════════════════════════════════════════════════════
// 【瞄准 · AIM】
//   我读的是      :scripts/ 下 .mjs / .js 的源码文本(剥掉注释),不连线上。
//   我声称管的是  :脚本不绕过 mintThrowaway 去授权,也不按 admin 码找角色。
//   两者不同之处  :**我读的是写法,不是运行。** 一个把角色码拼出来的写法
//                   (`code=eq.${'ad' + 'min'}`)我看不见 —— 那一层由 mintThrowaway 的运行期拒绝兜着
//                   (它读 roles.is_system,不认名字)。我也看不见 scripts/ 之外(db/ 的 fixture 在事务里回滚,
//                   不在本闸范围)。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { join, relative, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { assertPinned, assertPopulation } from './lib/selfproof.mjs'

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const SCRIPTS = join(ROOT, 'scripts')
const HELPER = 'scripts/ephemeral.mjs'

// ── 判据里的几个字面量 —— 拼出来写,免得本文件自己的正文命中自己 ──────────────
const GRANT_TABLE = 'user' + '_roles'
const GRANT_PATH = '/rest/v1/' + GRANT_TABLE
const MARKER_FN = 'ephemeral' + 'GrantBody'
const ADMIN_LOOKUP = 'code=eq.' + 'admin'
const esc = (x) => x.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

const RULES = [
    { id: 'grant-marker', why: `自授标记 ${MARKER_FN}() 只许在 ${HELPER} 里用 —— 授权一律经 mintThrowaway`,
      re: new RegExp(`\\b${MARKER_FN}\\s*\\(`, 'g') },
    { id: 'admin-lookup', why: `按 ${ADMIN_LOOKUP} 找角色 —— 要"什么都看得见"用 mintThrowaway({ codes: 'all' }),要 admin 的码用 { cloneOf: 'admin' }`,
      re: new RegExp(`${esc(ADMIN_LOOKUP)}(?![\\w-])`, 'g') },
    { id: 'grant-post', why: `往 ${GRANT_PATH} 写一条授权 —— 一律经 mintThrowaway`,
      // 裸集合路径(后面直接是引号)= 插入;带查询串的,下面再看紧跟着的 method
      re: new RegExp(`${esc(GRANT_PATH)}([^'"\`\\s]*)['"\`]`, 'g'),
      post: (src, m) => {
          const q = m[1]
          if (q === '' || /^\?on_conflict=/.test(q)) return true
          const tail = src.slice(m.index, m.index + 400)
          const call = tail.split(/\)\s*[;\n]/)[0]           // 到这一次调用收尾为止
          return /method\s*:\s*['"`]POST['"`]/.test(call)
      } },
    { id: 'grant-sdk', why: `supabase-js 往 ${GRANT_TABLE} 插 —— 一律经 mintThrowaway`,
      re: new RegExp(`\\.from\\(\\s*['"\`]${GRANT_TABLE}['"\`]\\s*\\)\\s*\\.(insert|upsert)\\b`, 'g') },
    { id: 'grant-rpc', why: `set_${GRANT_TABLE} 这支 RPC 改的是真授权 —— 脚本不许调`,
      re: new RegExp(`rpc/set_${GRANT_TABLE}\\b|\\.rpc\\(\\s*['"\`]set_${GRANT_TABLE}['"\`]`, 'g') },
]

// ── 剥注释(保持长度与换行,于是偏移与行号不变)───────────────────────────────
// strings=true 时连字符串 / 模板 / 正则字面量的内容也抹掉(找函数体的花括号用)。
// 返回 { text, lost }:lost = 文件结束时不在"代码"状态(解析器丢了位置)。
const KW_BEFORE_REGEX = new Set(['return', 'typeof', 'instanceof', 'in', 'of', 'new', 'delete', 'void', 'throw', 'case', 'do', 'else', 'yield', 'await'])
function blank(src, { strings = false } = {}) {
    const out = src.split('')
    const n = src.length
    const sp = (i) => { if (out[i] !== '\n') out[i] = ' ' }
    let i = 0, mode = 'code', depth = 0
    const tpl = []                // 每进一层 ${ 记下当时的花括号深度
    let lastSig = ''              // 上一个有意义的字符(判断 / 是除号还是正则)
    let lastWord = ''
    while (i < n) {
        const c = src[i], d = src[i + 1]
        if (mode === 'code') {
            if (c === '/' && d === '/') { while (i < n && src[i] !== '\n') sp(i++); continue }
            if (c === '/' && d === '*') {
                sp(i++); sp(i++)
                while (i < n && !(src[i] === '*' && src[i + 1] === '/')) sp(i++)
                if (i >= n) return { text: out.join(''), lost: 'block-comment' }
                sp(i++); sp(i++); continue
            }
            if (c === "'" || c === '"') {
                const q = c; i++
                while (i < n && src[i] !== q && src[i] !== '\n') {
                    if (src[i] === '\\') { if (strings) sp(i); i++ }
                    if (strings) sp(i)
                    i++
                }
                if (i >= n || src[i] === '\n') return { text: out.join(''), lost: `string@${i}` }
                i++; lastSig = q; lastWord = ''; continue
            }
            if (c === '`') { mode = 'tpl'; i++; continue }
            if (c === '/') {
                const regexOk = lastSig === '' || '(,=:[!&|?{};+-*%<>~^'.includes(lastSig) || KW_BEFORE_REGEX.has(lastWord)
                if (regexOk) {
                    i++
                    let cls = false
                    while (i < n && (cls || src[i] !== '/') && src[i] !== '\n') {
                        if (src[i] === '\\') { if (strings) sp(i); i++ }
                        else if (src[i] === '[') cls = true
                        else if (src[i] === ']') cls = false
                        if (strings) sp(i)
                        i++
                    }
                    if (i >= n || src[i] === '\n') return { text: out.join(''), lost: `regex@${i}` }
                    i++
                    while (i < n && /[a-z]/i.test(src[i])) i++
                    lastSig = '/'; lastWord = ''; continue
                }
            }
            if (c === '{') depth++
            if (c === '}') {
                depth--
                if (tpl.length && tpl[tpl.length - 1] === depth) { tpl.pop(); mode = 'tpl'; i++; continue }
            }
            if (/\s/.test(c)) { i++; continue }
            if (/[\w$]/.test(c)) {
                let j = i
                while (j < n && /[\w$]/.test(src[j])) j++
                lastWord = src.slice(i, j); lastSig = 'w'; i = j; continue
            }
            lastSig = c; lastWord = ''; i++; continue
        }
        // mode === 'tpl'
        if (c === '\\') { if (strings) { sp(i); sp(i + 1) } i += 2; continue }
        if (c === '`') { mode = 'code'; lastSig = '`'; lastWord = ''; i++; continue }
        if (c === '$' && d === '{') { tpl.push(depth); depth++; mode = 'code'; lastSig = '{'; lastWord = ''; i += 2; continue }
        if (strings) sp(i)
        i++
    }
    if (mode !== 'code' || tpl.length) return { text: out.join(''), lost: mode === 'tpl' ? 'template' : 'template-expr' }
    return { text: out.join(''), lost: null }
}
const lineOf = (src, idx) => src.slice(0, idx).split('\n').length

// ── 两条互不相干的路数文件 ───────────────────────────────────────────────────
const isScript = (name) => name.endsWith('.mjs') || name.endsWith('.js')
function walk(dir, skip = null) {                 // 扫描器自己的遍历
    const found = []
    for (const name of readdirSync(dir).sort()) {
        if (name === 'node_modules') continue
        const p = join(dir, name)
        if (statSync(p).isDirectory()) found.push(...walk(p, skip))
        else if (isScript(name)) {
            const rel = relative(ROOT, p)
            if (rel === skip) continue               // --inject=blind
            found.push(rel)
        }
    }
    return found
}
function independentList() {                      // 另一条路:find(与上面那段 JS 没有一行共用)
    const outp = execFileSync('find', [SCRIPTS, '-name', 'node_modules', '-prune', '-o', '-type', 'f',
        '(', '-name', '*.mjs', '-o', '-name', '*.js', ')', '-print'], { encoding: 'utf8' })
    return outp.split('\n').filter(Boolean).map((p) => relative(ROOT, p)).sort()
}

// ── 一次扫描:files 是要读的清单,override 是"内存里换掉某几个文件的正文" ────────
function scan(files, override = new Map()) {
    const violations = []
    const lost = []
    let parsed = 0
    let callSites = 0
    const callSiteFiles = new Set()
    let helperText = null
    for (const rel of files) {
        const src = override.has(rel) ? override.get(rel) : readFileSync(join(ROOT, rel), 'utf8')
        parsed++                                   // 解析器自己的计数:真的读过、剥过的文件
        const { text, lost: why } = blank(src)
        if (why) lost.push(`${rel}(剥注释停在 ${why})`)
        if (rel === HELPER) { helperText = src; continue }
        for (const rule of RULES) {
            rule.re.lastIndex = 0
            for (const m of text.matchAll(rule.re)) {
                if (rule.post && !rule.post(text, m)) continue
                const ln = lineOf(text, m.index)
                violations.push({ file: rel, line: ln, rule: rule.id, why: rule.why,
                                  snippet: src.split('\n')[ln - 1].trim().slice(0, 140) })
            }
        }
        // 调用点数在【连字符串也抹掉】的正文上数 —— 一句提到它的报错文案(比如本文件自己的)不算调用点
        const sites = [...blank(src, { strings: true }).text.matchAll(/\bmintThrowaway\s*\(/g)].length
        if (sites) { callSites += sites; callSiteFiles.add(rel) }
    }
    return { violations, lost, parsed, callSites, callSiteFiles, helperText }
}

// ── (c) mintThrowaway 在、并带着【无条件】的 is_system 拒绝 ────────────────────
const REFUSAL_RE = /if\s*\(([^)]*\bis_system\b[^)]*)\)\s*throw\s+new\s+Error\(\s*[`'"]THROWAWAY_REFUSES_SYSTEM_ROLE\|/g
function helperProblems(helperSrc) {
    if (helperSrc == null) return [`${HELPER} 没被扫到`]
    const { text } = blank(helperSrc, { strings: true })
    const start = text.search(/export\s+async\s+function\s+mintThrowaway\s*\(/)
    if (start < 0) return [`${HELPER} 里没有 export async function mintThrowaway(…)`]
    // 函数体:从参数表之后的第一个 { 起,花括号配平(字符串 / 注释已抹掉)
    let i = text.indexOf(')', start)
    i = text.indexOf('{', i)
    let depth = 0, end = -1
    for (let j = i; j < text.length; j++) {
        if (text[j] === '{') depth++
        else if (text[j] === '}' && --depth === 0) { end = j; break }
    }
    if (end < 0) return [`${HELPER} 的 mintThrowaway 函数体配不平`]
    const body = helperSrc.slice(i, end + 1)
    const refusals = [...body.matchAll(REFUSAL_RE)].map((m) => m[1])
    const unconditional = refusals.filter((cond) => !/refusalOff|inject/i.test(cond))
    const problems = []
    if (!refusals.length) problems.push(`${HELPER} 的 mintThrowaway 里没有 is_system 拒绝(THROWAWAY_REFUSES_SYSTEM_ROLE)`)
    else if (!unconditional.length)
        problems.push(`${HELPER} 的 mintThrowaway 里每一处 is_system 拒绝都挂着注入开关 —— 至少要有一处不受它影响`)
    if (!/\.is_system\b/.test(body) || !/select=[^`'"]*is_system/.test(body))
        problems.push(`${HELPER} 的 mintThrowaway 没有读 roles.is_system —— 拒绝必须按库里的标记,不按名字`)
    return problems
}

// ── 一次完整的判决 —— 返回红的理由(空 = 绿)────────────────────────────────
function verdict({ skip = null, override = new Map(), quiet = false } = {}) {
    const files = walk(SCRIPTS, skip)
    const indep = independentList()
    const r = scan(files, override)
    const reds = []
    // 覆盖率:扫描器读过的文件数 vs 一条与它无关的路数出来的文件数 —— 数与集合都要对得上
    if (r.parsed !== indep.length || r.parsed !== files.length) {
        const missing = indep.filter((f) => !files.includes(f))
        const extra = files.filter((f) => !indep.includes(f))
        reds.push(`覆盖率:扫描器读了 ${r.parsed} 个文件,find 数出 ${indep.length} 个`
            + (missing.length ? `;扫描器没读:${missing.join('、')}` : '')
            + (extra.length ? `;find 没有:${extra.join('、')}` : ''))
    }
    if (r.lost.length) reds.push(`剥注释那一层丢了位置(这些文件后半截我看不见):${r.lost.join('、')}`)
    if (r.callSites === 0) reds.push('mintThrowaway 调用点 0 个 —— 没有人在用那一种造法,或者解析器瞎了')
    for (const p of helperProblems(r.helperText)) reds.push(p)
    for (const v of r.violations) reds.push(`${v.file}:${v.line}  [${v.rule}] ${v.why}\n      ${v.snippet}`)
    if (!quiet) {
        console.log(`· 扫描 ${r.parsed} 个文件(find 独立数出 ${indep.length} 个)· mintThrowaway 调用点 ${r.callSites} 处,分布在 ${r.callSiteFiles.size} 个文件`)
    }
    return { reds, r }
}

// ── 注入:往一个文件末尾补回旧写法(只在内存里)──────────────────────────────
const OLD_PATTERN = '\n;{ const roles = await (await rest(\'/rest/v1/roles?select=id&' + ADMIN_LOOKUP + '\')).json()\n'
    + '  await rest(\'' + GRANT_PATH + '\', { method: \'POST\', body: JSON.stringify(' + MARKER_FN + '(accountId, roles[0].id)) }) }\n'
const withOldPattern = (rel) => readFileSync(join(ROOT, rel), 'utf8') + OLD_PATTERN
const redNames = (reds, rel) => reds.some((x) => x.startsWith(`${rel}:`))

function main() {
    const arg = process.argv.find((a) => a.startsWith('--inject='))
    const inject = arg ? arg.slice('--inject='.length) : null

    if (!inject) {
        const { reds, r } = verdict()
        // 覆盖断言(scripts/lib/selfproof.mjs,与其它量具同一套):总体非空;扫描器数的文件 = 另一条与它无关的路数的文件;
        //   调用点 > 0。上面 verdict 已经把差在哪几个文件说出来(注入 blind 那一格读的就是它);这里是同一个事实的【会退出】的那一半。
        assertPopulation('check-throwaway-grants', 'scripts/ 下扫描到的 .mjs / .js', r.parsed)
        assertPinned('check-throwaway-grants', '扫描器读的文件数 ↔ find 独立数出的文件数', r.parsed, independentList().length)
        assertPopulation('check-throwaway-grants', 'mintThrowaway 调用点', r.callSites)
        if (reds.length) {
            console.error(`\n✗ check-throwaway-grants:${reds.length} 处 ——`)
            for (const x of reds) console.error('  ' + x)
            return 1
        }
        console.log('✓ check-throwaway-grants:没有脚本绕过 mintThrowaway 去授权或按 admin 码找角色;mintThrowaway 带着无条件的 is_system 拒绝。')
        return 0
    }

    if (inject === 'all') {
        // 每一个已改造的文件逐个注入,每一格都必须红并点名那个文件
        const base = verdict({ quiet: true })
        if (base.reds.length) {
            console.error('✗ --inject=all:不注入时就已经是红的 —— 先修干净,注入的结论才有意义:')
            for (const x of base.reds) console.error('  ' + x)
            return 1
        }
        const targets = [...base.r.callSiteFiles].sort()
        let bit = 0
        for (const rel of targets) {
            const { reds } = verdict({ override: new Map([[rel, withOldPattern(rel)]]), quiet: true })
            const ok = redNames(reds, rel)
            if (ok) bit++
            const rules = reds.filter((x) => x.startsWith(`${rel}:`)).map((x) => x.match(/\[([\w-]+)\]/)?.[1]).join(',')
            console.log(`  ${ok ? 'RED  ' : 'GREEN'} ${rel}${ok ? `  (${rules})` : '  ← ★ 注入没有咬人'}`)
        }
        console.log(`· --inject=all:${bit}/${targets.length} 个已改造的文件在注入之下变红`)
        if (!targets.length) { console.error('✗ 没有一个已改造的文件 —— 这一格什么也没证明'); return 1 }
        return bit === targets.length ? 0 : 1
    }

    if (inject === 'blind') {
        const victim = walk(SCRIPTS).find((f) => f !== HELPER)
        console.log(`· --inject=blind:扫描器的遍历跳过 ${victim}`)
        const { reds } = verdict({ skip: victim })
        const cov = reds.filter((x) => x.startsWith('覆盖率'))
        for (const x of reds) console.error('  ' + x)
        if (cov.length && cov[0].includes(victim)) { console.error('✗ 覆盖率断言红了,并点名被跳过的文件(注入咬到了)'); return 1 }
        console.error('✗✗ 注入没有咬人:扫描器跳过了一个文件,覆盖率断言却没红'); return 0
    }

    if (inject === 'refusal-removed') {
        const src = readFileSync(join(ROOT, HELPER), 'utf8')
        const stripped = src.replace(REFUSAL_RE, 'if (false) throw new Error(`REMOVED|')
        if (stripped === src) { console.error('✗✗ 注入没找到可删的拒绝 —— 这一格什么也没证明'); return 2 }
        const { reds } = verdict({ override: new Map([[HELPER, stripped]]) })
        for (const x of reds) console.error('  ' + x)
        if (reds.some((x) => x.includes('is_system 拒绝'))) { console.error('✗ 拒绝不在了,闸红了(注入咬到了)'); return 1 }
        console.error('✗✗ 注入没有咬人:拒绝删掉了,闸还是绿的'); return 0
    }

    // 一个具体的文件
    const rel = inject.startsWith('scripts/') ? inject : `scripts/${inject}`
    if (!walk(SCRIPTS).includes(rel)) {
        console.error(`✗ --inject=${inject}:scripts/ 下没有这个 .mjs / .js。可选:<scripts/ 下的相对路径> / all / blind / refusal-removed`)
        return 2
    }
    const { reds } = verdict({ override: new Map([[rel, withOldPattern(rel)]]) })
    for (const x of reds) console.error('  ' + x)
    if (redNames(reds, rel)) { console.error(`✗ 注入的旧写法被拦住了,点名 ${rel}`); return 1 }
    console.error(`✗✗ 注入没有咬人:${rel} 里补回了旧写法,闸没点它的名`); return 0
}

process.exit(main())
