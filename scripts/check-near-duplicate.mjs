#!/usr/bin/env node
// scripts/check-near-duplicate.mjs
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么这个文件存在】GO-4 把 DICT-ADMIN 的近重复比较抽了出来,给
// suppliers / customers 复用。**抽取的对象是一条已经上线、已经做过故障注入的机制**,
// 所以第一件事不是"用它",而是"证明它没变"。
//
// 而这里有一个必须照直说的发现:**抽取之前,那条检查【没有任何自动化覆盖】**——
// 仓库里没有测试框架,没有 fixture 碰得到它(它是 app 层 TypeScript,
// 而 fixtures 是 SQL),`errNearDuplicate` 这个 key 只出现在它自己的文件里。
// 所以"让它原有的 fixture 原样通过"这条要求【无法照字面满足:那些 fixture 不存在】。
// 本文件就是补上的那一份 —— 它现在是这条比较逻辑的第一份自动化覆盖。
//
// 它断言两件事:
//   ① 规范化与折叠的**逐条行为**(空白、大小写、内部连续空白、空串);
//   ② **抽取前后一致**:把 DICT-ADMIN 原来那一行内联逻辑
//      (`r.code.toLowerCase() === code.toLowerCase()`,配 `trim().replace(/\s+/g,' ')`)
//      与新的 findNearDuplicate 在同一批输入上对拍,答案必须逐个相同。
//      ②【不是】重写一遍新实现 —— 它是把【旧的那一份】留在这里当基准。
// ════════════════════════════════════════════════════════════════════════════
import { normaliseIdentityText, foldForCompare, findNearDuplicate } from '../lib/nearDuplicate.ts'

let fail = 0
const eq = (label, got, want) => {
    const ok = JSON.stringify(got) === JSON.stringify(want)
    if (!ok) { fail++; console.error(`  ✗ ${label}\n      得到 ${JSON.stringify(got)}\n      应为 ${JSON.stringify(want)}`) }
    return ok
}

console.log('== 近重复:一个定义,两种处置(GO-4)==\n')

// ① 逐条行为
eq('去首尾空白', normaliseIdentityText('  Acme  '), 'Acme')
eq('压内部连续空白', normaliseIdentityText('Acme   Battery  Recycling'), 'Acme Battery Recycling')
eq('不动大小写(存的是人写下的样子)', normaliseIdentityText('ACME Pte Ltd'), 'ACME Pte Ltd')
eq('折叠用于比较', foldForCompare('  ACME   Battery '), 'acme battery')
eq('空串折叠成空串', foldForCompare('   '), '')

// ② 抽取前后对拍 —— 左边是 DICT-ADMIN 抽取【之前】那一份,原样留着当基准
const legacyNormalise = (raw) => raw.trim().replace(/\s+/g, ' ')
const legacyFind = (candidate, rows) => {
    const code = legacyNormalise(candidate)
    return rows.find((r) => r.code.toLowerCase() === code.toLowerCase())?.code
}
const CORPUS = [
    'NMC', 'nmc', 'Nmc', ' NMC ', 'NM C', 'lfp', 'LFP',
    'Acme Battery Recycling Pte Ltd', 'ACME BATTERY RECYCLING PTE LTD',
    'Acme  Battery   Recycling Pte Ltd', 'Acme Battery Recycling Pte. Ltd.',
    '', '   ', 'black_mass', 'BLACK_MASS', '不存在的值',
]
const ROWS = [{ code: 'NMC' }, { code: 'LFP' }, { code: 'black_mass' },
              { code: 'Acme Battery Recycling Pte Ltd' }]
let compared = 0
for (const c of CORPUS) {
    const legacy = legacyFind(c, ROWS)
    const shared = findNearDuplicate(c, ROWS, (r) => r.code)
    // 【空串的一处刻意差异,写出来而不是抹掉】旧实现对空候选会命中【任何空 code】;
    // 新实现对空候选一律返回 undefined(空不是一个值)。语料里没有空 code 的行,
    // 所以两者在【真实数据上】逐个相同 —— 这一句就是那个断言。
    eq(`对拍「${c}」`, shared, legacy)
    compared++
}
if (compared === 0) { console.error('  ✗ 对拍了 0 条 —— 语料是空的,这不是"通过"'); fail++ }

console.log(`\n对拍 ${compared} 条输入,旧实现与抽取后的共享实现答案一致。`)
if (fail) { console.error(`\n✗ ${fail} 条断言失败 —— 抽取【改变了行为】,这是一个发现,不是一个待调整的测试。`); process.exit(1) }
console.log('✓ 全部通过。')
