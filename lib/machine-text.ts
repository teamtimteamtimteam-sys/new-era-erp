// lib/machine-text.ts
// ════════════════════════════════════════════════════════════════════════════
// BUGFIX-1b(2026-09-12)· 一串机器字走到人面前 —— 【最后一格:兜底】
// ════════════════════════════════════════════════════════════════════════════
//
// 【这个文件是哪一条账的落点】
//   docs/machine-text-reaching-humans.md(CCY-1,2026-08-10)立的案:
//   「本该是人话的字符串,以机器形态出现在屏幕上」。那份文档明写这一族
//   「该有自己的一刀」。BUGFIX-1 round 1 把机制量清楚了:
//   **43 支 localize*Error,其中 40 支以「把生字符串原样吐出去」收尾**
//   —— 那不是疏忽,是一条写下来的设计(`// genuine non-coded DB error → surface verbatim`)。
//   本文件不是在补一个漏,它是在**换掉那条设计的最后一格**。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【它只替换两类,第三类一个字都不许碰】★★(Tim 2026-09-12 的裁定,见
//    docs/forward-queue.md「BUGFIX-1b 的裁定 · Q3」)
// ════════════════════════════════════════════════════════════════════════════
//   ① **生的错误码** —— `UPPER_SNAKE`,可带 `|detail`(例:`TAX_CODE_REQUIRED|supplier`);
//   ② **数据库自己的报错原文** —— `… does not exist` / `violates …` /
//      `permission denied` / `PGRST…` 那一族;
//   ③ ★ **数据库返回的【人话句子】原样留着。** 它们的**措辞**归 POLISH-1。
//      【理由,照直抄 Tim 的】一句人话即使写得不好,也比一句通用兜底告诉人更多东西。
//
// ════════════════════════════════════════════════════════════════════════════
// ★【「看起来像一个码」是怎么判的 —— 一句话,以及它两个方向的风险】★
// ════════════════════════════════════════════════════════════════════════════
//   判据:**【整串】去掉首尾空白之后,恰好是一个 UPPER_SNAKE 码(≥3 字符),
//   后面可以跟一个 `|` 和任意细节** —— 不是「串尾出现过一个大写词」。
//
//   * **误判(把人话当成码)的风险**:一句人话必须**通篇没有小写字母、没有空格**
//     才会被当成码。实测这棵树的数据库**从来不故意抛人话**
//     (`db/**/*.sql` 的 1367 处 RAISE 里,人话 0 条),而 supabase-js 自己的
//     句子(「Failed to fetch」)都带小写。☞ **风险接近零,但它不是零**:
//     一条全大写的第三方短消息会被换掉。
//   * **漏判(把码当成人话放过去)的风险**:一个码如果**前面被包了一层前缀**
//     (例如 `xyz: TAX_CODE_REQUIRED|supplier`),整串判据不认它,于是它
//     **仍然原样到屏幕上 —— 也就是今天的行为**。☞ **漏判只会退回现状,
//     不会比今天更坏**,而误判会毁掉信息。所以判据故意选**紧**的那一边。
//     (实测:PostgREST 把 `RAISE EXCEPTION` 的 message 原样放进 `error.message`,
//      不加前缀 —— 见 BUGFIX-1b 交回报告 §D 的读数。)
//
// ════════════════════════════════════════════════════════════════════════════
// ★【原始那一串不会消失,它去了日志】★
//   `console.error('[machine-text] …')` —— 与 `app/components/nav/ModuleBar.tsx`
//   那条 `[nav] …` 同一个写法。屏幕上看不见 SQL 原文,而追查它的人仍然拿得到。
// ════════════════════════════════════════════════════════════════════════════

import { getTranslations } from '@/lib/i18n/server'

/** 整串恰好是一个码(可带 `|detail`)。★ 注意是 `^…$`,不是串尾匹配 —— 见抬头。 */
const WHOLE_CODE_RE = /^([A-Z][A-Z0-9_]{2,})(?:\|[\s\S]*)?$/

/**
 * 数据库 / PostgREST 自己的报错措辞。
 * 【为什么是一张词表而不是一条通则】这一类没有形状,只有习惯用语;
 * round 1 的探针在这里栽过一次(词表里放了裸的 `'column '`,6/8 是假阳性),
 * 所以这里每一条都**带上下文**,不放裸词。
 */
const DB_MESSAGE_RE = new RegExp([
    'does not exist',
    'violates [a-z-]+ constraint',
    'violates row-level security',
    'permission denied for',
    'duplicate key value',
    'null value in column',
    'invalid input syntax for',
    'value too long for',
    'out of range',
    'deadlock detected',
    'could not (?:serialize|open|connect|obtain)',
    'PGRST\\d{3}',
    'JWT expired',
    'relation "[^"]*" does not exist',
    'function [a-z0-9_.]+\\([^)]*\\) does not exist',
].join('|'), 'i')

export type RawShape =
    | { kind: 'code'; marker: string }
    | { kind: 'db'; marker: string }
    | { kind: 'human' }

/**
 * ★ 短而稳定的标记 —— FNV-1a(32 位)→ base36,取 6 位,前缀 `DB-`。
 * 【为什么不直接把数据库那句话放进去】那正是本文件要挡住的东西。
 * 【为什么不哈希成一个更短的东西】人要能在日志里搜到它:同一句话永远给同一个标记。
 * 归一化只做「首尾空白 + 连续空白压成一个空格」——**不剥引号里的值**,
 * 因为两条只差一个列名的报错,是两件事,不该共用一个标记。
 */
function shortMarker(message: string): string {
    const norm = message.trim().replace(/\s+/g, ' ')
    let h = 0x811c9dc5
    for (let i = 0; i < norm.length; i++) {
        h ^= norm.charCodeAt(i)
        h = Math.imul(h, 0x01000193) >>> 0
    }
    return 'DB-' + h.toString(36).toUpperCase().padStart(7, '0').slice(-6)
}

/** 这一串是哪一类。★ 判据全在这里一处,别处不许再写第二份。 */
export function classifyRawError(message: string): RawShape {
    const raw = (message ?? '').trim()
    if (!raw) return { kind: 'human' }
    const m = raw.match(WHOLE_CODE_RE)
    if (m) return { kind: 'code', marker: m[1] }
    if (DB_MESSAGE_RE.test(raw)) return { kind: 'db', marker: shortMarker(raw) }
    return { kind: 'human' }
}

/**
 * ★ 这一串【如果】要被兜底,兜出来的是哪句话 —— 人话句子返回 `null`。
 *
 * ★★【它为什么是一个单独的导出,而不是内嵌在下面那支里】★★
 *   `lib/action-refusal.ts` 的 `refuseFromCoded` 靠一条契约分界:
 *   **「本地化器把原样那一串还回来了」= 它没认出这个码**。
 *   本刀换掉兜底之后,那条契约【按构造失效】—— 映射器再也不会把原样那一串还回来。
 *   ☞ 于是那一支改成拿**同一个输入**问一次「兜底会说什么」,
 *     再比对本地化器给的话:相等 = 它是兜底,不是认出来了。
 *   **同一个输入 + 同一种语言 ⇒ 同一句输出**,所以这个比对是精确的,不是启发式的。
 *   ★ 它【不写日志】—— 那一支只是在问一个问题,不是在报告一次失败。
 */
export async function fallbackTextFor(message: string): Promise<string | null> {
    const shape = classifyRawError(message)
    if (shape.kind === 'human') return null
    return (await getTranslations())('common.errUnexpected', { code: shape.marker })
}

/**
 * ★★ 所有 `localize*Error` 的【共用兜底】。
 *
 * @param message 映射器手里那一串原文(白名单没有认出来的那一串)。
 * @param where   哪一支映射器 —— 只进日志,不进屏幕。
 * @returns 生码 / 数据库报错 → Q14 那句人话(带一个能追查的短码);
 *          人话句子 → **原样返回**。
 */
export async function fallbackForRawError(message: string, where: string): Promise<string> {
    const raw = (message ?? '').trim()
    const shape = classifyRawError(raw)
    if (shape.kind === 'human') return message
    // 原文去日志 —— 屏幕上没有它了,追查的人仍然要拿得到。
    console.error(`[machine-text] ${where} (${shape.kind}/${shape.marker}): ${raw}`)
    return (await getTranslations())('common.errUnexpected', { code: shape.marker })
}

/**
 * 同一件事的**同步**版本,给那两处拿不到 `await` 的调用点
 * (日历的来源汇总与导出路由的正文各自有自己的形状)。
 * ★ 它【不】翻译 —— 翻译要 `await`;调用方自己把 `marker` 喂进 `t()`。
 * 返回 `null` 表示「这是人话,原样用」。
 */
export function markerForRawError(message: string, where: string): string | null {
    const raw = (message ?? '').trim()
    const shape = classifyRawError(raw)
    if (shape.kind === 'human') return null
    console.error(`[machine-text] ${where} (${shape.kind}/${shape.marker}): ${raw}`)
    return shape.marker
}
