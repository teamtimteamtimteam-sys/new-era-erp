#!/usr/bin/env node
// scripts/check-masked-reads.mjs
//
// ════════════════════════════════════════════════════════════════════════════
// 【它回答一个问题,而且只回答那一个】
//     **app 里有哪些查询【直接读一张被遮蔽的表】,而不是读它的 _masked 伴生视图?**
//
// 【它【不】回答"这条查询会不会 42501"】—— 而这不是谨慎,是它的诚实边界。
// EQP-1c-c-fu 期间写过一个一次性扫描器,它声称能指出"选了被扣下的列"。
// **它把八个 PostgREST 嵌入名当成了列名**,其中至少一个后来实测是通得过的。
// 一个夸大自己的检查会被人忽略,而一个被忽略的检查【比没有更坏】——
// 因为它让人以为那块地面有人看过。
//
// 所以判词只有一句:**这条查询读的是遮蔽表,请改读 <表>_masked。**
// 那句话永远为真、永远可执行,而且不需要它分辨列名与嵌入名。
//
// ────────────────────────────────────────────────────────────────────────────
// 【它看得见什么】
//   ✓ `.from('<遮蔽表>').select(...)` —— 字面量表名的【读取】,app/ 与 lib/ 下的 .ts / .tsx
//   ✓ `.select('… <遮蔽表> ( … ) …')` —— select 串里的【内嵌关系】(CHECK-1 补)
//   ✓ **写入(insert/update/upsert/delete)【不报】** —— 遮蔽是 SELECT 这一侧的事;
//     表级写授权照常,而 _masked 视图是只读的。把写也报出来就是又一次夸大。
//   ✓ 遮蔽表清单【从生成的类型里推】(lib/database.types.ts 里凡是有
//     `<x>_masked` 视图的表),所以线上加一张遮蔽表、下一次 types:gen 之后
//     这个检查自动跟着变 —— 不在这里抄第二份清单
//
// 【CHECK-1(2026-08-31)补上的那一半:**select 串里的内嵌关系**】
//   此前它只认 `.from('<表>')`,而 PostgREST 还有另一条读同一张表的路 ——
//   把表名写在 select 串里当内嵌:`.select('id, processing_outputs ( unit_cost_base )')`。
//   **那条路一个字都不经过 .from(),所以它整个是隐形的。**
//   实测代价:/inventory/output/[materialId] 内嵌了 processing_outputs 基表,
//   于是整条查询对【每一个真实用户】返回 42501,而页面上的 `?? []` 把它吞成空列表 ——
//   **屏幕上平静地写着「没有库存」,而库里有 6 批。** 门全绿。
//   现在两条路都认,判词一样:**改读 <表>_masked**(实测:换成遮蔽视图后同一条查询 200)。
//
// 【它看不见什么 —— 点名,不含糊】
//   ✗ **PostgREST 的嵌入名与列名它分不开**。所以它不判断"选了哪一列",
//     只判断"读的是哪一张表"。上面那段就是这条限制的由来。
//     内嵌那一半同理:它认的是"这个标识符后面跟着一个左括号",
//     也就是内嵌【关系名】的形状。一个恰好与遮蔽表同名的【函数调用】写在
//     select 串里会被误认 —— 本仓库今天没有这种写法,而这条限制写在这里,
//     不藏着。
//   ✗ **拼出来的 select 串**:`.select(\`...\${x}...\`)` 里由变量决定的部分。
//     字面量那部分照常扫。
//   ✗ **认不出动词的链**:`.from('x')` 之后六行内没有 select/insert/... 的
//     —— 不猜,不报。宁可漏一个,不要报一个假的。
//   ✗ **动态表名**:`.from(someVariable)` —— 表名不是字面量时它看不见
//   ✗ **动态列清单**:select 字符串由变量拼出来的
//   ✗ **运行时才成形的任何东西**(rpc 里的 SQL、字符串模板拼出的查询)
//   ✗ **服务端密钥的连接**:那条路绕过 RLS 与列授权,本检查也管不着
//   ✗ 它不看 db/ —— 那是 gate 的 colgrant / colreader 的地盘
//
// 【它怎么拦人:一条只能往下走的棘轮】
//   本检查落地时,app 里【已经】有 71 处这样的读取(EQP-1c-c-fu 估的是"三十来处")。
//   把它们一次改完不是本刀的事(那要一处处重新判断,而 D6 要求先把它们记下来)。
//   所以判词是**增量**的:`scripts/masked-reads-baseline.json` 记着每个
//   〈文件 · 表〉今天有几处,**多出来一处就红**,少了只提示去刷新基线。
//
//   为什么不是"报告一下就算了":本仓库有一条写在 AGENTS.md 里的规矩 ——
//   **一个报告了却不拦的判词不是闸**。而为什么不是"一律红":那会让 71 处
//   历史债把每一次构建都挡住,于是人学会跳过这道门 —— 与 `--reach` 曾经是
//   默认时发生的事一样。棘轮两头都躲开了:**新债当场拦,旧债在册可查。**
//
//   基线的键是〈文件 · 表〉而不是〈文件 · 行号〉—— 行号会因为任何一次无关的
//   编辑而漂移,而一个天天误报的基线,最后会被人删掉。
//
// 【为什么这条检查非有不可】EQP-1c-c-fu 实测:app 里有一批查询直连遮蔽表,
// 今天不炸【只是因为它们恰好没点到被扣下的那几列】。往那张表加一列
// (WO-1a 的三件事之一)就可能让其中一条当场 42501,而页面上的 `?? []`
// 会把它变成一张空表 —— **门全绿,页面全空**。那正是 FIN-6 那 42 分钟的形状。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs'
import { join, relative } from 'node:path'

const ROOT = process.cwd()
const SCAN_DIRS = ['app', 'lib']

// ── 遮蔽表清单:从生成的类型里推,不抄第二份 ──────────────────────────────
function maskedTables() {
    const src = readFileSync(join(ROOT, 'lib/database.types.ts'), 'utf8')
    const views = new Set([...src.matchAll(/^ {6}(\w+_masked):/gm)].map((m) => m[1]))
    if (views.size === 0) {
        // 【解析出 0 个不是"没有遮蔽表"】—— 与 check-i18n 的后缀解析同一条规矩。
        console.error('✗ check-masked-reads:从 lib/database.types.ts 里解析出 0 个 _masked 视图。')
        console.error('  解析不出来【不是】空集合。先确认 types:gen 跑过、文件格式没变。')
        process.exit(2)
    }
    return new Map([...views].map((v) => [v.replace(/_masked$/, ''), v]))
}

function walk(dir, out = []) {
    for (const e of readdirSync(dir)) {
        const p = join(dir, e)
        if (statSync(p).isDirectory()) walk(p, out)
        else if (/\.(ts|tsx)$/.test(e)) out.push(p)
    }
    return out
}

const MASKED = maskedTables()

// ── CHECK-1:select 串里的内嵌关系 ───────────────────────────────────────────
// PostgREST 的内嵌写法是 `<关系>( 列, … )`,可以带别名(`别名:<关系>(…)`)、
// 带外键提示(`<关系>!fk_name(…)`)、并且可以嵌套。判据只认【标识符后面跟左括号】,
// 与 .from() 那一半一样【只看表名,不看列名】—— 抬头写着为什么。
const EMBED_RE = /(?:^|[,\s(])(?:[a-z_][\w]*\s*:\s*)?([a-z_][\w]*)(?:!\w+)?\s*\(/g

// `.select(` 与它后面那个字符串字面量之间可能隔着【整行注释】——
// /inventory/output/[materialId] 就是这么写的(注释解释了这一处为什么改成遮蔽视图)。
// 第一版没有剥注释,于是【恰恰漏掉了那个被拿来当例子的文件】。
// 所以先按行把整行 `//` 注释换成空行(保住行号),再扫。
function stripLineComments(text) {
    return text.split('\n').map((l) => {
        const t = l.trimStart()
        return (t.startsWith('//') || t.startsWith('*') || t.startsWith('/*')) ? '' : l
    }).join('\n')
}

const SELECT_RE = /\.select\(\s*(`[^`]*`|'[^']*'|"[^"]*")/g

function embedHits(rel, rawText) {
    const text = stripLineComments(rawText)
    const out = []
    for (const m of text.matchAll(SELECT_RE)) {
        const body = m[1].slice(1, -1)
        const line = text.slice(0, m.index).split('\n').length
        const seen = new Set()
        for (const e of body.matchAll(EMBED_RE)) {
            const t = e[1]
            // `<表>_masked ( … )` 正是要的写法 —— MASKED 的键是基表名,
            // 所以遮蔽视图本身不会命中。这里不必特判,写下来是为了让读的人放心。
            if (MASKED.has(t)) seen.add(t)
        }
        for (const t of seen) {
            out.push({ file: rel, line, table: t, view: MASKED.get(t),
                text: body.replace(/\s+/g, ' ').slice(0, 90), kind: 'embed' })
        }
    }
    return out
}

// ── IDLE-DRAFT:lib/maskedTables.ts 必须与这里算出来的同一份集合一致 ──
// 那个生成文件是【草稿留存】判断"这张表带不带受限数据"的依据。它一旦落后,
// 线上新加的遮蔽表就会安静地开始留存草稿 —— 也就是把薪资/身份写进浏览器存储。
// 本检查已经把这份集合算出来了,所以顺手比一次,不另起一个检查器。
{
    const genPath = join(ROOT, 'lib/maskedTables.ts')
    let gen = ''
    try { gen = readFileSync(genPath, 'utf8') } catch { gen = '' }
    const inGen = new Set([...gen.matchAll(/^ {4}'([a-z_]+)',$/gm)].map((m) => m[1]))
    const expected = new Set(MASKED.keys())
    const missing = [...expected].filter((t) => !inGen.has(t))
    const extra = [...inGen].filter((t) => !expected.has(t))
    if (missing.length || extra.length) {
        console.error('✗ lib/maskedTables.ts 与 lib/database.types.ts 不同步。')
        if (missing.length) console.error('   缺少:', missing.join(', '))
        if (extra.length) console.error('   多出:', extra.join(', '))
        console.error('   【怎么改】node scripts/gen-masked-tables.mjs,然后提交。')
        console.error('   【为什么它要红】草稿留存据此决定不为哪些表留草稿;')
        console.error('   它落后一张表,就意味着那张表的受限数据开始被写进浏览器存储。')
        process.exit(1)
    }
    console.log(`   lib/maskedTables.ts 与遮蔽表集合一致(${expected.size} 张)`)
}
const files = SCAN_DIRS.flatMap((d) => walk(join(ROOT, d)))
const hits = []

for (const f of files) {
    const rel = relative(ROOT, f)
    const raw = readFileSync(f, 'utf8')
    hits.push(...embedHits(rel, raw))
    const lines = raw.split('\n')
    lines.forEach((line, i) => {
        // 只认字面量表名 —— 变量表名是上面点过名的盲区
        const m = line.match(/\.from\(\s*'([a-z_]+)'\s*\)/)
        if (!m) return
        const tbl = m[1]
        if (!MASKED.has(tbl)) return
        // 【只报【读】,不报写】—— 遮蔽是 SELECT 这一侧的事:
        // 表级 INSERT/UPDATE 授权照常,写入本来就该走表,不走视图
        // (视图是只读的)。把写也报出来就是又一次夸大,而夸大的检查会被忽略。
        // 判据:从 .from(...) 起往后看几行,这条链上先出现的是 select 还是写动词。
        const tail = lines.slice(i, i + 6).join(' ')
        const after = tail.slice(tail.indexOf(m[0]) + m[0].length)
        const verb = after.match(/\.(select|insert|update|upsert|delete)\s*\(/)
        if (!verb) return                       // 认不出动词:不猜,不报(盲区,抬头已点名)
        if (verb[1] !== 'select') return        // 写入 —— 正确的做法就是直连表
        hits.push({ file: rel, line: i + 1, table: tbl, view: MASKED.get(tbl), text: line.trim() })
    })
}

const BASELINE = join(ROOT, 'scripts/masked-reads-baseline.json')

// 键:〈文件 · 表〉。行号会漂,文件与表不会。
// 键:〈文件 · 表 · 读法〉。行号会漂,文件与表不会。
// 【读法也进键】——直连与内嵌是两种写法、两处改法,合成一个计数会让"改好一处直连、
// 同时新增一处内嵌"在基线上互相抵消,而那正是棘轮要拦的东西。
const counts = new Map()
for (const h of hits) {
    const k = `${h.file} :: ${h.table}` + (h.kind === 'embed' ? ' :: embed' : '')
    counts.set(k, (counts.get(k) ?? 0) + 1)
}

if (process.argv.includes('--update-baseline')) {
    const obj = Object.fromEntries([...counts].sort((a, b) => a[0].localeCompare(b[0])))
    writeFileSync(BASELINE, JSON.stringify(obj, null, 2) + '\n')
    console.log(`✓ 基线已刷新:${counts.size} 个〈文件 · 表〉,共 ${hits.length} 处。`)
    process.exit(0)
}

let base
try {
    base = JSON.parse(readFileSync(BASELINE, 'utf8'))
} catch {
    console.error('✗ check-masked-reads:读不到基线 scripts/masked-reads-baseline.json。')
    console.error('  读不到【不是】空基线 —— 那会把 71 处历史债当成 71 处新债。')
    console.error('  头一次生成:node scripts/check-masked-reads.mjs --update-baseline')
    process.exit(2)
}

const added = []      // 新增的〈文件 · 表〉,或同一处变多了
const gone = []       // 改好了(或文件没了)—— 只提示,不拦
for (const [k, n] of counts) {
    const was = base[k] ?? 0
    if (n > was) added.push({ k, was, now: n })
}
for (const k of Object.keys(base)) {
    if ((counts.get(k) ?? 0) < base[k]) gone.push({ k, was: base[k], now: counts.get(k) ?? 0 })
}

console.log('== 读取遮蔽表的地方(.from() 直连 + select 串里的内嵌)==')
console.log('   判词:**这条查询读的是遮蔽表,请改读 <表>_masked。**')
console.log('   它【不】断言"这条会 42501" —— 它分不开嵌入名与列名(抬头写着为什么)。')
console.log(`   基线:${hits.length} 处在册(见 docs/known-issues.md 的 MASKED-READS 条)。`)
console.log('')

if (gone.length) {
    console.log('· 少了几处 —— 有人改好了,或者文件动了。基线可以收紧:')
    for (const g of gone) console.log(`     ${g.k}   ${g.was} → ${g.now}`)
    console.log('  刷新:node scripts/check-masked-reads.mjs --update-baseline')
    console.log('')
}

if (added.length === 0) {
    console.log('✓ 没有【新增】的遮蔽表读取(直连与内嵌都算)。')
    process.exit(0)
}

console.log('✗ 新增了读取遮蔽表的地方:')
for (const a of added) {
    const parts = a.k.split(' :: ')
    const [file, tbl] = parts
    const isEmbed = parts[2] === 'embed'
    console.log(`     ${file}`)
    console.log(`       ${isEmbed ? '【select 串里的内嵌】' : '【.from() 直连】'}`
        + `读的是 ${tbl},应当读 ${MASKED.get(tbl)}   (在册 ${a.was} 处,现在 ${a.now} 处)`)
    for (const h of hits.filter((x) => x.file === file && x.table === tbl
        && (x.kind === 'embed') === isEmbed)) {
        console.log(`       第 ${h.line} 行: ${h.text.slice(0, 90)}`)
    }
}
console.log('')
console.log('【怎么改 · 直连】把 .from(\'<表>\') 换成 .from(\'<表>_masked\')。')
console.log('【怎么改 · 内嵌】把 select 串里的 `<表> ( … )` 换成 `<表>_masked ( … )`。')
console.log('  内嵌遮蔽视图是【可行的】,不是理论 —— FX-DISPLAY-1 实测:')
console.log('  /inventory/output/[materialId] 换成 processing_outputs_masked 之后同一条查询 200,')
console.log('  而换之前它对每一个真实用户都是 42501、被 `?? []` 吞成「没有库存」。')
console.log('那张视图【已经存在】,列名一致;被扣下的列在视图里按权限呈现为 null,')
console.log('而不是让整条查询 42501 —— 这正是它存在的理由(见 lib/permissions.ts)。')
console.log('')
console.log('【确实该直连表的话】(极少见,例如写入路径被误判)——')
console.log('先确认它真的不是读,再把这一处连同理由记进 docs/known-issues.md,')
console.log('然后 --update-baseline。**不要**为了让门变绿而直接刷新基线。')
process.exit(1)
