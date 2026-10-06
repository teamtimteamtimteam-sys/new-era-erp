#!/usr/bin/env node
// db/scripts/2026-10-05-u1b-render-live-trails.mjs
// U1-B · 把线上证明(db/scripts/2026-10-05-u1b-live-proof.sql)吐出来的 record_trail 原始行,用应用【自己的】造句器
// (lib/trail/render.ts 的 fromRecordTrail + buildEntries,与 app/components/trail/AuditTrail.tsx 同一条路)说成英文,
// 再逐条核对委托书点名的那几句措辞在不在。只读一个日志文件,不碰库、不碰网络。
// 跑法:node db/scripts/2026-10-05-u1b-render-live-trails.mjs <proof 日志>
// 退出码:0 每一句都在 · 1 有一句不在 · 2 日志里没有审计记录(读不到 = 不知道,不是通过)
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const ROOT = process.cwd()
const imp = (p) => import(join(ROOT, p))
const R = await imp('lib/trail/render.ts')
const T = await imp('lib/trail/text.ts')
const C = await imp('lib/trail/catalogue.generated.ts')
const D = await imp('lib/dates.ts')
const MV = await imp('messages/trail-machine-values.ts')
const CM = await imp('lib/currencyMap.ts')

const dict = {
    text: T.TRAIL_TEXT, fields: C.TRAIL_FIELDS, tables: C.TRAIL_TABLES, enums: C.TRAIL_ENUMS, machine: MV.TRAIL_MACHINE_VALUES,
    baseCurrency: 'SGD', formatDate: (v) => D.formatDate(v, 'en'), formatStamp: (v) => D.formatTrailStamp(v), bankCurrency: CM.currencyOfBank,
}

const log = readFileSync(process.argv[2], 'utf8')
const trails = {}
for (const m of log.matchAll(/U1B_TRAIL (\w+) (\[.*\])\s*$/gm)) trails[m[1]] = JSON.parse(m[2])
if (!Object.keys(trails).length) { console.error('✗ 日志里一条 U1B_TRAIL 都没有 —— 读不到,不是通过'); process.exit(2) }
// 证明全在一笔事务里,而审计记录按 txid 把一笔事务说成一条(change-log §9.4)。应用里每一个动作是它自己的一笔事务 ——
//   所以按证明记下的每一步开始的时刻(U1B_MARKS,clock_timestamp)把行切回一步一条,与分开的几次动作留下的样子相同。
const marks = JSON.parse(log.match(/U1B_MARKS (\[.*\])\s*$/m)?.[1] ?? 'null')
if (!Array.isArray(marks) || marks.length < 8) { console.error('✗ 日志里没有完整的 U1B_MARKS —— 切不回一步一条'); process.exit(2) }
// 【微秒】比:几步之间只隔几百微秒,Date.parse 只到毫秒,会把一步的行算进下一步(第一版实测就是这么把更正并进了作废)
const micros = (at) => BigInt(Date.parse(at.replace(/\.\d+/, ''))) * 1000n + BigInt(((at.match(/\.(\d+)/)?.[1] ?? '') + '000000').slice(0, 6))
const stepOf = (at) => { let k = 0; for (let i = 0; i < marks.length; i++) if (micros(marks[i].at) <= micros(at)) k = i + 1; return k }

const lineText = (l) => l.t === 'change' ? `${l.label}: ${l.old.text} → ${l.new.text}` : l.t === 'value' ? `${l.label}: ${l.value.text}`
    : l.t === 'heading' ? `[${l.text}${l.part ? ' · ' + l.part.text : ''}]` : `(${l.text})`
const said = {}
for (const [subject, rows] of Object.entries(trails)) {
    const root = rows.find((r) => r.ctx)
    const currency = typeof root?.ctx?.currency === 'string' ? root.ctx.currency : null
    const recordId = rows[0]?.row_key?.id ?? null
    const converted = rows.map((r) => {
        const row = R.fromRecordTrail(r)
        if (r.prelog || !r.occurred_at) return row
        const k = stepOf(r.occurred_at)
        return { ...row, group: 'S' + k, order: marks.length + 1 - k }
    })
    const entries = R.buildEntries(dict, converted, { currency, subject, recordId })
    said[subject] = entries.map((e) => [e.title + (e.titlePart ? ' · ' + e.titlePart.text : ''), ...e.lines.map(lineText),
        e.reason ? `Reason: ${e.reason.text}` : null].filter(Boolean).join(' | '))
    console.log(`── ${subject}`)
    for (const s of said[subject]) console.log('   ' + s)
}

// 委托书点名的措辞(读它们的审计记录,确认措辞)
const WANT = [
    ['sales_order', /Line added/i, 'a line added to the shipped order'],
    ['sales_order', /customer wants 5 more/, 'with the amendment reason'],
    ['equipment', /^Downtime voided.*Reason: U1B proof: entered on the wrong machine/m, 'the void with its reason'],
    ['equipment', /^Downtime corrected/m, 'the correction'],
    ['purchase_order', /^Purchase order closed.*Reason: U1B proof: supplier cannot deliver the rest/m, 'closed with its reason'],
    ['purchase_order', /^Purchase order reopened.*Reason: U1B proof: supplier found the stock/m, 'reopened with its reason'],
    ['purchase_order', /^Deep discharge judgement recorded/m, 'the deep-discharge judgement'],
    ['processing_run', /ZZ-U1B-A1/, 'the machine named on the run'],
]
let bad = 0
for (const [subject, re, what] of WANT) {
    const ok = (said[subject] ?? []).some((s) => re.test(s))
    console.log(`${ok ? '✓' : '✗'} ${subject}: ${what}`)
    if (!ok) bad++
}
// 与审计记录的那条规矩一起:notes 不再被改写 —— 关闭 / 重开那两条里不许出现 "Notes:"
const notesChanged = (said.purchase_order ?? []).some((s) => /^Purchase order (closed|reopened).*Notes:/.test(s))
console.log(`${notesChanged ? '✗' : '✓'} purchase_order: closing and reopening do not change Notes`)
if (notesChanged) bad++
console.log(`RENDER_OWN_EXIT=${bad ? 1 : 0}`)
process.exit(bad ? 1 : 0)
