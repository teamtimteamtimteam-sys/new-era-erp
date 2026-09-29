// lib/trail/machineTokens.ts
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1a(Tim 的 Q41)· 机器字检出器 —— 审计记录与变更记录页上【不许出现】的东西
// ════════════════════════════════════════════════════════════════════════════
// 两处用它,判据只有这一份:scripts/check-trail-wording.mjs(构建时,对造出来的每一句)与
// scripts/smoke-routes.mjs(冒烟时,对三个真页面与汇总页的真 HTML)。
//
// 【它认什么】uuid · 蛇形标识符(表名与列名的样子:purchase_order_lines、estimated_unit_price)·
//   点号代码(module.purchasing.view)· 全大写代码(TRAIL_NOT_PERMITTED、ACCOUNT_CREATE)· JSON(`{"`、`":`、`$restricted`)·
//   "null" · 数据库角色名(postgres / service_role / authenticated / anon)· ISO 日期与时刻(2026-09-01、…T06:33)。
//   ★ 允许:"Restricted" 与 "(empty)" —— 它们是这套东西【自己】说的话。
// 【它不认什么,照直说】一个单词的表名 / 列名(roles、status、notes)同时是英文单词 —— 分不开,不装作分得开。
//   蛇形的那一类(绝大多数)一个都漏不掉。邮箱先剥掉再扫(fx@test.local 里的 test.local 不是代码)。
// 【一个 import 都没有】两支 .mjs 脚本用 Node 的 type-stripping 直接 import 本文件。
// ════════════════════════════════════════════════════════════════════════════

export type TokenHit = { kind: string; token: string }

const RULES: [string, RegExp][] = [
    ['uuid', /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi],
    ['iso-timestamp', /\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/g],
    ['iso-date', /\b\d{4}-\d{2}-\d{2}\b/g],
    ['json', /[{[]\s*"|"\s*:|\$restricted|\{\s*\}|\[\s*\]/g],
    ['null', /\bnull\b/gi],
    ['db-role', /\b(postgres|service_role|authenticated|anon)\b/g],
    ['upper-code', /\b[A-Z][A-Z0-9]*_[A-Z0-9_]+\b/g],
    // 两段都至少两个字:e.g. 不是代码,module.purchasing.view 是
    ['dotted-code', /\b[a-z][a-z0-9_]+\.[a-z][a-z0-9_]+(?:\.[a-z0-9_]+)*\b/g],
    ['snake-identifier', /\b[a-z][a-z0-9]*_[a-z0-9_]+\b/g],
]
const EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g

/** 扫一段已经上屏的文字,返回每一处机器字(空数组 = 干净)。 */
export function machineTokens(text: string): TokenHit[] {
    const s = text.replace(EMAIL, ' ')
    const out: TokenHit[] = []
    for (const [kind, re] of RULES) {
        for (const m of s.matchAll(re)) out.push({ kind, token: m[0] })
    }
    return out
}

/**
 * 【自证】每次调用检出器的脚本先跑这一格:一组已知的坏样本必须【每一个】都被认出,
 * 一句已知的好话必须【一个】都不被认出。任一不成立 → 这把尺是瞎的,不许拿它下结论
 * (AGENTS.md「覆盖率本身必须是一条断言」)。返回失败说明,空数组 = 尺是好的。
 */
export function selfProof(detect: (text: string) => TokenHit[] = machineTokens): string[] {
    const bad: [string, string][] = [
        ['uuid', 'Approved by 926c9811-c1ee-49ab-9ab8-f6686d92b6f9'],
        ['snake-identifier', 'estimated_unit_price 10 → 11'],
        ['dotted-code', 'Needs module.purchasing.view'],
        ['upper-code', 'TRAIL_NOT_PERMITTED|role'],
        ['json', '{"$restricted": true}'],
        ['null', 'Notes null → Pay 50/50'],
        ['db-role', 'No session · service_role'],
        ['iso-date', 'Order date 2026-09-03 → 2026-09-08'],
        ['iso-timestamp', 'At 2026-09-01T06:33:00Z'],
    ]
    const fails: string[] = []
    for (const [kind, sample] of bad) {
        if (!detect(sample).some((h) => h.kind === kind)) fails.push(`the detector missed ${kind}: "${sample}"`)
    }
    const good = 'Purchase order amended · 3 changes · Order date 03/09/2026 → 08/09/2026 · Estimated unit price Restricted → 305,550.00 SGD · ' +
        'Notes (empty) → Payment schedule 50% Advanced · PO-2026-0010 (since deleted) · System (automatic) · Removed account · ' +
        'e.g. a supplier that has since been deleted · fx236-all@test.local · 29/09/2026 12:39'
    const hits = detect(good)
    if (hits.length) fails.push(`the detector flagged a clean sentence: ${hits.map((h) => `${h.kind} "${h.token}"`).join(', ')}`)
    return fails
}
