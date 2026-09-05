#!/usr/bin/env node
// scripts/check-cjk-rendered.mjs — 渲染到屏幕上的中文硬串,只许【减少】。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【为什么 check-i18n 抓不到这一类,而且【永远】抓不到】★★
// ════════════════════════════════════════════════════════════════════════════
// check-i18n 问的是一个关于【键】的问题:
//     「代码里引用到的每一个键,en 与 zh 里是不是都有?」
// 而一个硬写在 JSX 里的中文字面量**一个键都不引用**。它没有键可查,
// 于是它不在那个检查器的【宇宙】里 —— 这不是它覆盖面上的一个缺口,
// 是它问的问题根本不含这一类。**两道检查因此不能合并**,
// 谁将来想「整合一下」,请先读完这一段。
//
// 【它咬过一次,而且是最贵的那种】COPY-1(2026-09-06)之前:
// data-table.tsx 里 14 处中文硬串,而**97 个页面 import 这一个组件** ——
// 于是英文界面上每一页都印一句中文,而 check-i18n 一路是绿的。
// 分页、空态、全选、列显隐、以及那句解释「第一页为什么是全体前 N 名」的话,
// 六个人里有几个只读英文。**绿灯不代表看过,它代表没有人问过这个问题。**
//
// 【口径】只盯 survey-cjk-strings.mjs 判成 `D-rendered` 的那一类 ——
//   即:排除了取样页、刻意双语、开发者用的 throw/console、
//   formatMoneyBare 的文档参数(它被 void 掉,【永不渲染】)、
//   入库的规范值、以及语言切换器【之后】,真正会走到人眼前的中文。
//   分类器与勘察脚本【是同一个】(scripts/survey-cjk-strings.mjs 导出的 scanCjk),
//   免得闸和勘察各长一套判据然后悄悄分家。
//
// 【棘轮】基线里已有的,放行(每一条都过过眼,见 docs/known-issues.md 的 COPY-1 条);
//   基线外【新增】的,红。基线变短是好事,刷新它。
//
// 用法:node scripts/check-cjk-rendered.mjs
//       node scripts/check-cjk-rendered.mjs --update-baseline
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { scanCjk } from './survey-cjk-strings.mjs'

const ROOT = process.cwd()
const BASELINE = join(ROOT, 'scripts/cjk-rendered-baseline.json')

const hits = scanCjk(ROOT).filter((h) => h.cat === 'D-rendered')
// 键用【文件 :: 文本】,不用行号 —— 行号会随无关的编辑漂移,
// 那会让基线天天要刷新,而一个天天要刷新的基线等于没有基线。
const counts = {}
for (const h of hits) {
    const k = `${h.file} :: ${h.text}`
    counts[k] = (counts[k] ?? 0) + 1
}

if (process.argv.includes('--update-baseline')) {
    writeFileSync(BASELINE, JSON.stringify(Object.fromEntries(Object.entries(counts).sort()), null, 2) + '\n')
    console.log(`✓ 基线已刷新:${Object.keys(counts).length} 条`)
    process.exit(0)
}

let base
try {
    base = JSON.parse(readFileSync(BASELINE, 'utf8'))
} catch {
    console.error('✗ check-cjk-rendered:读不到 scripts/cjk-rendered-baseline.json。')
    console.error('  头一次生成:node scripts/check-cjk-rendered.mjs --update-baseline')
    process.exit(2)
}

const added = Object.keys(counts).filter((k) => !(k in base) || counts[k] > base[k])
const gone = Object.keys(base).filter((k) => !(k in counts) || counts[k] < base[k])

if (added.length) {
    console.log('✗ 屏幕上【新增】了写死的中文(它不经过 i18n,英文界面会原样印出来):')
    console.log('')
    for (const k of added) {
        const [file, text] = k.split(' :: ')
        const where = hits.filter((h) => `${h.file} :: ${h.text}` === k).map((h) => h.line).join(', ')
        console.log(`   ${file}  第 ${where} 行`)
        console.log(`     ${text}`)
    }
    console.log('')
    console.log('【怎么改】把这句话搬进 messages/en.ts 与 messages/zh.ts,调用点改成 t(键)。')
    console.log('  两种语言都要写 —— 只补一边,另一边会原样印出键名。')
    console.log('【它确实【不该】翻译】(入库的规范值、开发者看的 throw、刻意的双语)——')
    console.log('  那就让 survey-cjk-strings.mjs 的分类器认得它,而不是把它塞进基线;')
    console.log('  分类器认不出的形状,下一处会再犯一次。')
    console.log('**不要**为了让门变绿就直接刷新基线。')
    process.exit(1)
}

if (gone.length) {
    console.log(`✓ 少了 ${gone.length} 条(基线可以变短):`)
    for (const k of gone) console.log(`   ${k}`)
    console.log('  刷新:node scripts/check-cjk-rendered.mjs --update-baseline')
}
console.log(`✓ 屏幕上没有【新增】写死的中文(基线 ${Object.keys(base).length} 条)`)
// ════════════════════════════════════════════════════════════════════════════
// ★★【KNOWN LIMITATION —— 这道检查只认【中文】】★★
//
// 它问的是「有没有中文漏在 i18n 之外」。反过来的那一半 ——
// **一句只有英文的硬串** —— 它一个都抓不到,因为拉丁字母在代码里到处都是
// (类名、属性、枚举、注释),没有一条便宜的判据能把「文案」从中分出来。
//
// **一次绿的构建【不】意味着这一屏两种语言都有;它意味着没有【中文】漏在外面。**
//
// 本仓库眼下的形状让这个偏斜是划算的:文案先用中文写,英文是翻出来的,
// 所以漏网的几乎总是中文。**哪天这个前提变了,这道检查的价值就跟着变**,
// 记在 docs/known-issues.md 的 COPY-1 条。
// ════════════════════════════════════════════════════════════════════════════
