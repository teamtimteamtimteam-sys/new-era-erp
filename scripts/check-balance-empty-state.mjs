#!/usr/bin/env node
// scripts/check-balance-empty-state.mjs —— F14(MES-7b-1,2026-10-16;MES7A2CO-ROLLFORWARD-HIDDEN-WITHOUT-RUNS)
//
// 【瞄准 · AIM】
//   我读的是      :lib/balanceEmptyState.ts(Node 的 type-stripping import 进来【真的跑】)· app/operation/balance/page.tsx 的源码文本
//   我声称管的是   :/operation/balance 只在【加工的月份、加工的行、库存滚动的行三样都空】时才说"空" —— 一个没有加工单的库照样看得见库存滚动
//
// 【为什么要一支量具】这条规矩住在应用层,任何 fixture 都看不见它(MES-5b-1 那一行只问了两样,MES-7a-2 的版式普查量过那张空页而没发觉)。
//   ① 行为:真值表的 8 种组合逐一跑,只有 (0,0,0) 是空;
//   ② 接线:页面的 state 真的调了这一支,而且三样都传了(按源码文本认 —— 一个页面自己写一句 months.length === 0 && … 就绕开了它);
//   ③ 故障注入:CHECK_BALANCE_EMPTY_FAULT=two-sources 让被测函数换成【只看两样】的旧判据 —— 这一格必须红,否则这支量具是瞎的。
//   两者不同之处   :②认的是页面源码的【文本】,不是渲染出来的页 —— 渲染那一半由版式普查在一个没有加工单的本地重建上量(交回报告)。
//   覆盖断言:断言条数钉死 10 条(assertAssertionsRan)—— 一个 early return 会让它报绿而什么都没比。
// 退出码:0 干净 · 1 违规 · 2 量具坏了。
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { balancePageIsEmpty as real } from '../lib/balanceEmptyState.ts'
import { assertAssertionsRan } from './lib/selfproof.mjs'

const ROOT = process.cwd()
const FAULT = process.env.CHECK_BALANCE_EMPTY_FAULT ?? ''
// 旧判据(MES-5b-1):只看加工的月份与行 —— 故障注入用
const old = (c) => c.months === 0 && c.lines === 0
const balancePageIsEmpty = FAULT === 'two-sources' ? old : real

const failures = []
let ran = 0
for (const months of [0, 1]) for (const lines of [0, 3]) for (const rollForward of [0, 2]) {
    ran++
    const want = months === 0 && lines === 0 && rollForward === 0
    const got = balancePageIsEmpty({ months, lines, rollForward })
    if (got !== want) failures.push(`months=${months} lines=${lines} rollForward=${rollForward}:应当${want ? '是空' : '不是空'},判据说${got ? '空' : '不空'}`)
}
const page = readFileSync(join(ROOT, 'app/operation/balance/page.tsx'), 'utf8')
ran++
if (!/balancePageIsEmpty\(\{\s*months:\s*months\.length,\s*lines:\s*lines\.length,\s*rollForward:\s*roll\.length\s*\}\)/.test(page)) {
    failures.push('app/operation/balance/page.tsx 的 state 没有经 balancePageIsEmpty({ months, lines, rollForward }) 判 —— 三样里漏了一样,或者页面自己写了一份判据')
}
ran++
if (/months\.length === 0 && lines\.length === 0 \?/.test(page)) failures.push('页面里还留着只看两样的旧判据(months.length === 0 && lines.length === 0 ?)')

assertAssertionsRan('check-balance-empty-state', ran, 10)
if (failures.length) {
    console.error(`✗ check-balance-empty-state:${failures.length} 处`)
    for (const f of failures) console.error('   ' + f)
    if (FAULT) console.error(`   ★ 故障注入:${FAULT}`)
    process.exit(1)
}
console.log(`✓ check-balance-empty-state:真值表 8 种组合只有三样都空才是空;页面经同一支判据传了三样${FAULT ? `(★ 故障注入 ${FAULT} 却是绿的 —— 量具瞎了)` : ''}`)
process.exit(FAULT ? 2 : 0)
