#!/usr/bin/env node
// scripts/gen-manual-index.mjs
//
// ════════════════════════════════════════════════════════════════════════════
// SEARCH-1 · S7/S8 —— 把手册切成【可检索的段落】,并把它自己的版本号带出来
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么是生成一份文件,而不是运行时读 markdown】
//   `docs/manual-draft.md` 是一份【文档】,不是应用的一部分。运行时 `fs.readFile`
//   它,就要求那份 markdown 在部署产物里【也在】—— 而那要靠 Next 的文件追踪
//   把一个 docs/ 底下的文件拖进 serverless 包。**那条依赖没有任何一道闸看得见**,
//   它坏掉的样子是「本机搜得到,线上一条都搜不到」。
//   ☞ 所以照 `gen-deep-routes.mjs` 已经付过账的那条路:**生成 + 进 npm run build
//     的比对**。改了手册而没有重跑,构建当场变红。
//
// ★★【为什么生成到 `data/` 而【不是】`lib/`】★★
//   `app/globals.css` 把 Tailwind 的扫描源限死在 `../app` 与 `../lib`
//   (BUGFIX-1a:一句散文被扫进生产 CSS,`next dev` 每条路由 500)。
//   **这份文件里装的正是散文 —— 2043 行手册正文。** 放进 `lib/`,
//   Tailwind 会把手册的每一个词当成类名候选去扫。
//   ☞ 生成到 `data/`,而 `data/` 【故意】不在 `@source` 里:
//     它一个类名都不写,所以它不需要被扫,**而它不被扫正是本条的全部要点**。
//   ⚠ 下一个往 `data/` 里放【会写类名】的东西的人:那一刻起这段话不再成立,
//     要么别放,要么给 globals.css 加一行 `@source`(见那个文件的抬头)。
//
// ── 判据:什么是一个「段落」 ────────────────────────────────────────────────
//   手册的结构是 4 个 PART / 31 个编号小节(`## N.N`)/ 70 个三级标题(`###`)。
//   ★ **锚点 = 小节 + 三级标题 = 31 + 70 = 101** —— PART 自己【不是】锚点:
//     它是一个容器,它底下没有属于它自己的正文。SEARCH-0 量到的也是 101。
//   每一个锚点带【它自己的】正文(到下一个同级或更高级标题为止),
//   **不含它的子标题的正文** —— 否则一次命中会把半个 PART 还给读者。
//
// ── 版本:它是【手册自己的】版本,不是系统版本(Tim 的裁定,S8)────────────
//   `docs/manual-draft.md` 的前置区两行 `version:` / `issued:`。
//   `scripts/build-manual.py` 把它们印在封面上,本脚本把它们带进索引 ——
//   **同一份真源,两个读者**,不是两份声明。
//
// 用法:node scripts/gen-manual-index.mjs          比对(build 跑这个,不一致退 1)
//       node scripts/gen-manual-index.mjs --write  重新生成
// ════════════════════════════════════════════════════════════════════════════
//
// ==========================================================================
// 【瞄准 · AIM】
//   我读的是      :`docs/manual-draft.md` 的**文本**:前置区两行,以及 `#`/`##`/`###`
//                   三级标题与它们之间的正文行。
//   我声称管的是   :`data/manualIndex.generated.ts` 与那份 markdown **是一致的** ——
//                   101 个锚点、它们的标题与正文、以及手册自己的版本号。
//   两者不同之处   :★ **我不读 PDF。** 印出来的那一本由 `build-manual.py` 排版,
//                   而它读的是同一份 markdown。两者一致【由同源保证】,不由我检查:
//                   我看不见排版脚本有没有把版本号真的印上去。
//                   ★ 我也**不判断正文写得对不对** —— 手册落后于代码是 Tim 明确接受的
//                   (S8),那是一件编辑活,不是一条可机检的性质。
// ==========================================================================
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { assertPopulation, assertPinned } from './lib/selfproof.mjs'

const ROOT = process.cwd()
const SRC = join(ROOT, 'docs/manual-draft.md')
const OUT = join(ROOT, 'data/manualIndex.generated.ts')
const WRITE = process.argv.includes('--write')
const SELF = 'gen-manual-index'

// ── 前置区 ──────────────────────────────────────────────────────────────────
// `---\nkey: value\n…\n---` 开头的那一块。**必须存在** —— 缺了就是 S8 没落地,
// 而一个"版本号是空字符串"的手册结果会在屏幕上印出「来自手册 」这种半句话。
function frontMatter(md) {
    const m = md.match(/^---\n([\s\S]*?)\n---\n/)
    if (!m) {
        console.error('✗ gen-manual-index:docs/manual-draft.md 没有前置区。')
        console.error('  S8 要求手册带自己的 version: 与 issued:,而它们是搜索结果要显示的东西。')
        process.exit(1)
    }
    const meta = {}
    for (const line of m[1].split('\n')) {
        const kv = line.match(/^([A-Za-z_]+):\s*(.+?)\s*$/)
        if (kv) meta[kv[1]] = kv[2]
    }
    for (const k of ['version', 'issued']) {
        if (!meta[k]) {
            console.error(`✗ gen-manual-index:前置区里没有 ${k}: —— S8 要的是【两行】,不是一行。`)
            process.exit(1)
        }
    }
    return { meta, body: md.slice(m[0].length) }
}

// ── markdown → 纯文本 ───────────────────────────────────────────────────────
// 【只做减法】搜索比对的是【人读到的那些字】。粗体记号、行内代码的反引号、
// 表格的竖线、列表的项目符号 —— 它们在屏幕上是【格式】,不是内容。
// ⚠ 刻意【不】动大小写与标点:匹配那一侧自己会折叠大小写,而在这里折叠
//   会让返回给读者的那一段话看起来像是被机器嚼过的。
const toText = (s) =>
    s
        .replace(/`([^`]*)`/g, '$1')        // 行内代码
        .replace(/\*\*([^*]*)\*\*/g, '$1')  // 粗体
        .replace(/\*([^*]*)\*/g, '$1')      // 斜体
        .replace(/^\s*[-*]\s+/, '')         // 列表项目符号
        .replace(/^\s*\|/, ' ')             // 表格左竖线
        .replace(/\|\s*$/, ' ')             // 表格右竖线
        .replace(/\s*\|\s*/g, ' · ')        // 表格内竖线 → 间隔点
        .replace(/\s+/g, ' ')
        .trim()

// 表格的分隔行(|---|---|)不是内容,它是一行画出来的横线。
const isTableRule = (s) => /^\s*\|?[\s:|-]+\|[\s:|-]*$/.test(s) && s.includes('-')

const { meta, body } = frontMatter(readFileSync(SRC, 'utf8'))

// ── 切段 ────────────────────────────────────────────────────────────────────
const lines = body.split('\n')
let part = null           // 当前 PART 的标题
let manualTitle = null    // 手册自己的标题(第一个 `# `,不是 PART)
const passages = []
let cur = null            // 当前正在收正文的锚点

const flush = () => {
    if (!cur) return
    cur.text = toText(cur.buf.filter((l) => !isTableRule(l)).map(toText).join(' '))
    delete cur.buf
    passages.push(cur)
    cur = null
}

let subIdx = 0
let secNumber = null

for (const raw of lines) {
    const h1 = raw.match(/^# (.+)$/)
    const h2 = raw.match(/^## (.+)$/)
    const h3 = raw.match(/^### (.+)$/)

    if (h1) {
        flush()
        if (/^PART /i.test(h1[1])) part = h1[1].trim()
        else if (manualTitle === null) manualTitle = h1[1].trim()
        continue
    }
    if (h2) {
        flush()
        const m = h2[1].match(/^(\d+(?:\.\d+)*)\s+(.*)$/)
        secNumber = m ? m[1] : null
        subIdx = 0
        cur = {
            id: secNumber ? `sec-${secNumber}` : `sec-${passages.length}`,
            level: 2,
            part,
            number: secNumber,
            title: (m ? m[2] : h2[1]).trim(),
            buf: [],
        }
        continue
    }
    if (h3) {
        flush()
        subIdx += 1
        const m = h3[1].match(/^(\d+(?:\.\d+)*)\s+(.*)$/)
        cur = {
            id: `sec-${secNumber}-${subIdx}`,
            level: 3,
            part,
            // 三级标题里 68/70 条没有编号 —— 它们是一段流程里的步骤,不是查得到的号。
            number: m ? m[1] : null,
            title: (m ? m[2] : h3[1]).trim(),
            parentNumber: secNumber,
            buf: [],
        }
        continue
    }
    if (cur) cur.buf.push(raw)
}
flush()

// ── 自证:这一次切出来的东西对不对 ──────────────────────────────────────────
const sections = passages.filter((p) => p.level === 2)
const subs = passages.filter((p) => p.level === 3)
assertPopulation(SELF, '切出来的段落', passages.length)
// ★ 双向钉住:判据切出来的小节数,对上一条【不经过切段】的粗计数。
//   一条 early return 或一次正则失手会让前者掉下去,而后者不会跟着变。
assertPinned(SELF, '二级小节(##)', sections.length,
    body.split('\n').filter((l) => /^## /.test(l)).length,
    '切段那一层与数行那一层不一样瞎 —— 两条路数同一个总体。')
assertPinned(SELF, '三级标题(###)', subs.length,
    body.split('\n').filter((l) => /^### /.test(l)).length,
    '同上。')
if (!manualTitle) { console.error('✗ gen-manual-index:找不到手册标题(第一个非 PART 的 `# `)'); process.exit(2) }
const parts = [...new Set(passages.map((p) => p.part))].filter(Boolean)
assertPopulation(SELF, 'PART', parts.length, 1)
// 每一段都得有标题;正文可以为空(一个只有子标题的小节确实没有自己的正文),
// 而【正文全空】就是切段坏了,所以按总体算一次。
const withText = passages.filter((p) => p.text.length > 0).length
assertPopulation(SELF, '带正文的段落', withText)
for (const p of passages) {
    if (!p.title) { console.error(`✗ gen-manual-index:${p.id} 没有标题 —— 切段坏了`); process.exit(2) }
}

const esc = (s) => JSON.stringify(s)
const rows = passages.map((p) =>
    '    { id: ' + esc(p.id) +
    ', level: ' + p.level +
    ', part: ' + esc(p.part ?? '') +
    ', number: ' + (p.number === null ? 'null' : esc(p.number)) +
    ', title: ' + esc(p.title) +
    ', text: ' + esc(p.text) + ' },'
).join('\n')

const body_ts = `// ⚠️ 【生成文件,不要手改】由 scripts/gen-manual-index.mjs 产出。
// 改了它 \`npm run build\` 会红。判据与理由写在那个脚本的抬头里。
//
// ★【它为什么住在 data/ 而不是 lib/】★ 这里装的是手册正文 —— 散文。
//   Tailwind 的扫描源只有 app/ 与 lib/(app/globals.css 的 @source),
//   而 BUGFIX-1a 实测过一句散文被当成类名生成出来的后果(next dev 每条路由 500)。
//   **data/ 不在扫描源里,而它不在正是这份文件放在这里的理由。**
//
// 本次生成时的实测:手册 ${lines.length} 行 · PART ${parts.length} 个 ·
// 二级小节 ${sections.length} 个 · 三级标题 ${subs.length} 个 · 锚点合计 ${passages.length} 个。

/** 手册自己的版本号。★ 它【不是】测试者看到的那个系统版本(Tim 的 S8)。 */
export const MANUAL_VERSION = ${esc(meta.version)}
/** 这一版手册的签发日期,与封面上印的是同一个字符串。 */
export const MANUAL_ISSUED = ${esc(meta.issued)}
/** 手册的标题,与封面上印的是同一个字符串。 */
export const MANUAL_TITLE = ${esc(manualTitle)}

export type ManualPassage = {
    /** 稳定锚点:编号小节是 sec-3.7,它底下第 2 个三级标题是 sec-3.7-2。 */
    id: string
    /** 2 = 编号小节;3 = 它底下的三级标题。 */
    level: 2 | 3
    /** 所属 PART 的整行标题。 */
    part: string
    /** 小节号("3.7");三级标题多半没有号,那时是 null。 */
    number: string | null
    title: string
    /** 这一段【自己的】正文,不含子标题的正文。已剥掉 markdown 记号。 */
    text: string
}

/** 手册的 ${passages.length} 个天然锚点,按文档顺序。 */
export const MANUAL_PASSAGES: readonly ManualPassage[] = [
${rows}
]

/** 生成时的锚点计数 —— 让下一次 diff 一眼看得出是哪一层变了。 */
export const MANUAL_ANCHOR_COUNT = { sections: ${sections.length}, subsections: ${subs.length}, total: ${passages.length} } as const
`

if (WRITE) {
    mkdirSync(dirname(OUT), { recursive: true })
    writeFileSync(OUT, body_ts)
    console.log(`✓ 写入 ${passages.length} 个锚点(小节 ${sections.length} · 三级 ${subs.length})→ data/manualIndex.generated.ts`)
    console.log(`  手册版本 ${meta.version} · 签发 ${meta.issued}`)
    process.exit(0)
}

let current = ''
try {
    current = readFileSync(OUT, 'utf8')
} catch {
    console.log('')
    console.log('✗ data/manualIndex.generated.ts 不存在 —— 跑 `node scripts/gen-manual-index.mjs --write`。')
    process.exit(1)
}
if (current !== body_ts) {
    console.log('')
    console.log('✗ 手册索引过期了 —— 有人改了 docs/manual-draft.md,而搜索读的那份索引没有跟着重算。')
    console.log('  后果:搜索返回的是【上一版手册】的字,而结果上却印着新的版本号 ——')
    console.log('  一段陈旧的正文配一个新版本号,比没有版本号更坏。')
    console.log('  修法:node scripts/gen-manual-index.mjs --write,然后把生成的文件一起提交。')
    process.exit(1)
}
console.log(`✓ 手册索引:${passages.length} 个锚点(小节 ${sections.length} · 三级 ${subs.length})· ` +
    `版本 ${meta.version} · 签发 ${meta.issued} · 与生成文件一致`)
