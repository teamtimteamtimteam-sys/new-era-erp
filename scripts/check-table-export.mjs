#!/usr/bin/env node
// scripts/check-table-export.mjs
//
// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-1(Tim 2026-10-22,Q15)· 每一张表都声明了它的导出,或者在豁免清单上被点名
// ════════════════════════════════════════════════════════════════════════════
// 【瞄准 · AIM】
//   我读的是      :app/ 下每个 .tsx 的【源码文本】(注释抹掉后)里 <DataTable / <EditableTable / <table 的开标签与 DataTable 的属性区,
//                   以及 scripts/table-export-exemptions.mjs 那张清单
//   我声称管的是   :「每一张表都能导出,或者在清单上被点名」
//   两者不同之处   :我只看【属性区里有没有 exportSpec=】,不看它导出得对不对 —— 列的类型与完整性归 tsc(ExportableColumn),
//                   内容对不对归 TABLE-EXPORT-1 的线上证明;一个包了 DataTable 的组件(CellsTable · MassTable)在它的调用点上
//                   【不是】一个 <DataTable,我数不到那些调用点 —— 那两个组件把 exportSpec 写成必填,由 tsc 管每一个调用点。
//
// 它回答一个问题:**app/ 下每一处表(<DataTable / <EditableTable / 手搓 <table),
//   有没有哪一处既没有 exportSpec、也不在 scripts/table-export-exemptions.mjs 上?**
//
// 判据(五条,任何一条不成立就红):
//   ① 每一处 <DataTable 的属性区里有 `exportSpec=`,或者【那个文件的 DataTable】在清单上;
//   ② 每一处 <EditableTable / <table,【那个文件的那一种】在清单上(它们没有导出这一说,只能等 TABLE-EXPORT-3);
//   ③ STALE:清单上的一条,文件不存在,或者那一种在文件里已经【一处都不缺】了 —— 清单只许变短;
//   ④ Q5 / Q11 的唯一例外 `extension:` 只许出现在供应商与客户两张表里;
//   ⑤ 覆盖断言(AGENTS.md「覆盖率本身必须是一条断言」):按标签走出来的调用点数 = 剥掉注释后的正则数,且 > 0。
//
// 列的那一半(开了 exportSpec 的表每一列都有 exportAs)不在这里查 —— 那是 `tsc` 的事
// (DataTable 的 ExportOn<T> 把 columns 收窄成 ExportableColumn<T>),写成类型就不需要第二道文本闸。
//
// 故障注入(每次运行都跑,不靠人记得):
//   CHECK_TABLE_EXPORT_FAULT=blind          解析器读不出任何属性区 → 必须红(不许报"干净")
//   CHECK_TABLE_EXPORT_FAULT=drop:<file>    假装清单上没有那个文件 → 必须点名它
// ════════════════════════════════════════════════════════════════════════════

import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs'
import { join, relative } from 'node:path'
import { assertPopulation, assertPinned } from './lib/selfproof.mjs'
import { TABLE_EXPORT_EXEMPTIONS } from './table-export-exemptions.mjs'

const ROOT = process.cwd()
const FAULT = process.env.CHECK_TABLE_EXPORT_FAULT ?? ''
const EXTENSION_ALLOWED = new Set(['app/suppliers/SuppliersTable.tsx', 'app/sales/customers/CustomersTable.tsx'])

function walk(dir, out = []) {
    for (const name of readdirSync(dir)) {
        if (name === 'node_modules' || name === '.next' || name.startsWith('.')) continue
        const p = join(dir, name)
        if (statSync(p).isDirectory()) walk(p, out)
        else if (p.endsWith('.tsx')) out.push(p)
    }
    return out
}

/** 注释抹成空格(长度不变,行号不错位);字符串原样留着。与 check-datatable-phone 同一份写法。 */
function blankComments(src) {
    const out = src.split('')
    let i = 0
    while (i < src.length) {
        const two = src[i] + src[i + 1]
        if (two === '//') {
            while (i < src.length && src[i] !== '\n') { out[i] = ' '; i++ }
        } else if (two === '/*') {
            while (i < src.length && !(src[i] === '*' && src[i + 1] === '/')) { if (src[i] !== '\n') out[i] = ' '; i++ }
            out[i] = ' '; out[i + 1] = ' '; i += 2
        } else if (src[i] === "'" || src[i] === '"' || src[i] === '`') {
            const q = src[i]; i++
            while (i < src.length && src[i] !== q) { if (src[i] === '\\') i++; i++ }
            i++
        } else i++
    }
    return out.join('')
}

/** 一个调用点的属性区(先跳过泛型实参,再到第一个花括号外的 `>`)。 */
function propsBlockAt(src, start) {
    if (FAULT === 'blind') return null
    let i = start + 1
    while (i < src.length && !/[\s\n<>{]/.test(src[i])) i++
    if (src[i] === '<') {
        let g = 0
        for (; i < src.length; i++) {
            if (src[i] === '<') g++
            else if (src[i] === '>') { g--; if (g === 0) { i++; break } }
        }
    }
    const from = i
    let depth = 0
    for (; i < src.length; i++) {
        const ch = src[i]
        if (ch === '{') depth++
        else if (ch === '}') depth--
        else if (ch === '>' && depth === 0) return src.slice(from, i)
    }
    return null
}

const lineOf = (src, idx) => src.slice(0, idx).split('\n').length

const exempt = new Map()   // `${file}|${kind}` → entry
for (const e of TABLE_EXPORT_EXEMPTIONS) {
    if (FAULT.startsWith('drop:') && e.file === FAULT.slice(5)) continue
    const k = `${e.file}|${e.kind}`
    if (exempt.has(k)) { console.error(`✗ check-table-export:豁免清单重复一条 ${k}`); process.exit(1) }
    // PERMANENT:Tim 2026-10-22 TABLE-EXPORT-2 Q6 —— 永远不导出的那几条,理由写在条上
    // TABLE-EXPORT-2b-1(2026-10-23):TABLE-EXPORT-2 那一类清零之后不再收 —— 清单只许变短
    if (!['TABLE-EXPORT-3', 'PERMANENT'].includes(e.cut) || !e.why?.trim()) {
        console.error(`✗ check-table-export:豁免 ${k} 缺去处或理由`); process.exit(1)
    }
    exempt.set(k, e)
}

const files = walk(join(ROOT, 'app')).filter((p) => !relative(ROOT, p).startsWith('app/components/ui/'))
const problems = []
const used = new Set()          // 本次真的用到的豁免
let walked = 0, regexCount = 0, declared = 0
const byKind = { DataTable: 0, EditableTable: 0, table: 0 }

for (const abs of files) {
    const rel = relative(ROOT, abs)
    const raw = readFileSync(abs, 'utf8')
    const src = blankComments(raw)
    regexCount += (src.match(/<(DataTable|EditableTable)(?=[\s\n<])|<table(?=[\s\n>])/g) ?? []).length

    if (/\bextension:\s*\[/.test(src) && /exportSpec=/.test(src) && !EXTENSION_ALLOWED.has(rel)) {
        problems.push({ rel, line: 0, why: '`extension:` 只许供应商与客户两张表用(Tim Q5 / Q11:导出的列就是表的列)' })
    }

    for (const m of src.matchAll(/<(DataTable|EditableTable)(?=[\s\n<])|<table(?=[\s\n>])/g)) {
        walked++
        const kind = m[1] ?? 'table'
        byKind[kind]++
        const line = lineOf(src, m.index)
        const key = `${rel}|${kind}`
        if (kind === 'DataTable') {
            const block = propsBlockAt(src, m.index)
            if (block === null) { problems.push({ rel, line, why: '读不出这个 <DataTable 的属性区 —— 解析器可能坏了' }); continue }
            if (/\bexportSpec=/.test(block)) { declared++; continue }
        }
        if (exempt.has(key)) { used.add(key); continue }
        problems.push({
            rel, line,
            why: kind === 'DataTable'
                ? '这张表没有 exportSpec,也不在 scripts/table-export-exemptions.mjs 上。给它 exportSpec 与每一列的 exportAs(Tim 2026-10-22 TABLE-EXPORT-1)。'
                : `一个 <${kind}> 不在豁免清单上 —— 它要么换成 DataTable 并声明导出,要么点名进 TABLE-EXPORT-3。`,
        })
    }
}

for (const [k, e] of exempt) {
    if (!existsSync(join(ROOT, e.file))) problems.push({ rel: e.file, line: 0, why: `STALE:豁免清单上的 ${k} 文件不存在 —— 拿掉这一条` })
    else if (!used.has(k)) problems.push({ rel: e.file, line: 0, why: `STALE:${k} 已经一处都不缺了 —— 从豁免清单上拿掉(清单只许变短)` })
}

assertPopulation('check-table-export', 'app/ 下走到的 .tsx 文件', files.length)
if (walked === 0) {
    console.error('✗ check-table-export:走出 0 个表 —— 解析器坏了,不是"全都合格"。')
    process.exit(2)
}
assertPinned('check-table-export', '按标签走出的表 ↔ 剥掉注释后的正则数', walked, regexCount, '不等 = 有一处表被走漏了。')

const cuts = { 'TABLE-EXPORT-3': 0, PERMANENT: 0 }
for (const k of used) cuts[exempt.get(k).cut]++
if (problems.length === 0) {
    console.log(
        `✓ 表的导出:${walked} 处表(DataTable ${byKind.DataTable} · EditableTable ${byKind.EditableTable} · 手搓 table ${byKind.table})—— ` +
        `${declared} 处声明了导出 · 豁免 ${used.size} 条(TABLE-EXPORT-3 ${cuts['TABLE-EXPORT-3']} · PERMANENT ${cuts.PERMANENT})`
    )
    process.exit(0)
}
console.error(`\n✗ 表的导出:${problems.length} 处\n`)
for (const p of problems) console.error(`   ${p.rel}${p.line ? ':' + p.line : ''}\n     ${p.why}\n`)
process.exit(1)
