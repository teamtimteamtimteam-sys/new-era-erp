#!/usr/bin/env node
// scripts/check-bilingual-concat.mjs —— 双语【拼接】体检:
// 同一条记录的 _zh 与 _en 被【一起印】给人看,而不是按界面语言选一个。
//
// 【为什么 check-i18n 看不见这一类,而它需要另一支】
// check-i18n 查的是【文案文件里的键】(t('...'))。这一类字符串一次也不经过 t() ——
// 它们是【数据库列】(tax_codes.name_zh / gst_return_boxes.label_en 之类)。
// 那不是 check-i18n 的疏漏,是它的射程之外。所以另起一支,而不是把它撑大。
//
// 【它咬过一次,而且是被人眼咬出来的】GST-1/2/3 三刀里,同一个写法漏了【六处】:
// 税码下拉 ×4、GST 首页的税码表、F5 每一格的说明。构建绿、闸绿、冒烟 188 条全过 ——
// 因为没有任何一道检查在看这件事。**Tim 把界面切成英文,一眼看见"中文 / English"。**
// 六处同一个惯用法被漏掉,正是棘轮存在的理由:下一处应当让构建变红,而不是等下一次走查。
//
// 【判据:两个插值,同一个主语,中间只隔着字面文本】
//   {c.name_zh} / {c.name_en}          ← 抓
//   {locale === 'zh' ? a.x_zh : a.x_en} ← 【不抓】:这正是正确写法(同一个插值里)
//   csvCell(r.label_en), csvCell(r.label_zh) ← 【不抓】:两列,不是拼接
// 分隔符里不许出现 ( ) , < —— 那些意味着它们是两个参数 / 两个元素 / 跨标签,
// 而不是一段连排的文字。这条限制是这支检查【不误报】的全部依据。
//
// 【故意要印两种语言的地方怎么办】在那一行上写 `i18n-both:` 加理由。
// 【为什么是行内注释,不是一份基线文件】一次刻意的双语打印是【那一行的性质】,
// 理由要待在下一个读它的人眼前;而一份中心基线会与代码漂开,还能被整体刷新以变绿
// —— 本仓库对那件事的说法是"把债划掉,不是还债"。
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'

const ROOT = process.cwd()
const EXTS = new Set(['.tsx', '.ts'])
const SKIP_DIRS = new Set(['node_modules', '.next', '.git', 'public', 'assets'])

function* walk(dir) {
    for (const e of readdirSync(dir)) {
        if (SKIP_DIRS.has(e)) continue
        const p = join(dir, e)
        if (statSync(p).isDirectory()) yield* walk(p)
        else if (EXTS.has(p.slice(p.lastIndexOf('.')))) yield p
    }
}

// {…_zh…} <字面文本,不含 ( ) , <> {}> {…_en…}   两个方向都抓
const SEP = String.raw`[^{}()<>,]{0,12}`
const ZH_EN = new RegExp(String.raw`\{[^{}]*\b(\w+)\.(\w*_zh)\b[^{}]*\}${SEP}\{[^{}]*\b(\w+)\.(\w*_en)\b[^{}]*\}`)
const EN_ZH = new RegExp(String.raw`\{[^{}]*\b(\w+)\.(\w*_en)\b[^{}]*\}${SEP}\{[^{}]*\b(\w+)\.(\w*_zh)\b[^{}]*\}`)

const findings = []
const allowed = []
for (const file of walk(join(ROOT, 'app'))) {
    const lines = readFileSync(file, 'utf8').split('\n')
    lines.forEach((line, i) => {
        for (const re of [ZH_EN, EN_ZH]) {
            const m = line.match(re)
            if (!m) continue
            // 【同一个主语才算】{a.name_zh} / {b.name_en} 是两条记录,不是一次拼接
            if (m[1] !== m[3]) continue
            const rel = file.slice(ROOT.length + 1)
            if (/i18n-both:/.test(line)) { allowed.push(`${rel}:${i + 1}`); return }
            findings.push({ file: rel, line: i + 1, text: line.trim().slice(0, 110) })
            return
        }
    })
}

console.log('== 双语拼接体检 ==')
console.log('   判词:**同一条记录的 _zh 与 _en 被一起印出来,而不是按界面语言选一个。**')
console.log('   它【不】断言"翻译对不对" —— 那不是静态看得出来的。')
if (allowed.length) console.log(`   刻意双语打印(带 i18n-both: 注明理由):${allowed.length} 处 —— ${allowed.join(', ')}`)

if (findings.length === 0) {
    console.log(`✓ 没有把双语拼在一起印的地方(基线 0;刻意的那些要写 i18n-both: 加理由)`)
    process.exit(0)
}
console.log(`\n✗ ${findings.length} 处把 _zh 与 _en 拼在一起印:`)
for (const f of findings) console.log(`     ${f.file}:${f.line}\n       ${f.text}`)
console.log(`
【怎么改】按界面语言选一个 —— 仓库里另外一百多处的写法:
     服务端组件:const locale = await getLocale()   → {locale === 'zh' ? x.name_zh : x.name_en}
     客户端组件:const locale = useLocale()         → 同上
【确实要同时印两种语言的话】在那一行写 \`i18n-both: <理由>\`。
**不要**为了让门变绿而随手加那个注释:它是给下一个读这行的人看的理由,不是消音开关。`)
process.exit(1)
