// lib/search/match.ts
// ════════════════════════════════════════════════════════════════════════════
// SEARCH-1 · 匹配那一层 —— 纯函数,不碰权限、不碰数据库、不碰 i18n
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么单独一个文件】权限求值只许在 lib/modules.ts 的 allows() 里
// (check-permission-predicate ①)。把"哪些字命中了"与"这个人能不能看"
// 分成两层,是为了让第二层【只有一条路】—— 调用方拿本文件的命中结果,
// 再逐条过 allows()。本文件里连 perms 这个词都不出现。
//
// ★【折叠只折大小写与空白,不折别的】★
//   不做词干、不做同义词、不做拼音。理由是本仓库对"夸大自己的量具"那条:
//   一个会把 receive 匹配成 received 的搜索,也会把 credit 匹配成 creditor,
//   而没有任何人能从结果上看出它做过哪一次替换。
//   ☞ SEARCH-0 §8 把"排序、每次显示几条、防抖多少毫秒"列成【下一轮】的问题,
//     因为它们的前提(job ① 一次查几张表)还没定。**这里只做最直的那一件:
//     大小写不敏感的子串匹配**,并把这句话写下来,免得下一个人以为它更聪明。

/** 匹配用的折叠:大小写 + 首尾空白 + 内部连续空白。**不折别的。** */
export function fold(s: string): string {
    return s.toLowerCase().replace(/\s+/g, ' ').trim()
}

/**
 * 把用户打的那串切成【词】。多个词 = 全部都要命中(AND)。
 * 【为什么是 AND 不是 OR】"leave balance" 打出来的人要的是同时讲这两件事的那一条;
 * OR 会把只讲 leave 的 12 条全端上来,而那读起来像搜索没听懂。
 */
export function terms(query: string): string[] {
    return fold(query).split(' ').filter(Boolean)
}

/** 这些词【全部】出现在这段文字里吗。 */
export function matchesAll(haystack: string, ts: string[]): boolean {
    if (ts.length === 0) return false
    const h = fold(haystack)
    return ts.every((t) => h.includes(t))
}

/**
 * 命中处前后的一小段原文。
 *
 * ★【它返回的是【原文】,不是折叠过的文本】★ 折叠过的那一份只用来找位置;
 *   还给读者的必须是他在手册里读得到的那些字,否则他照着去手册里找会找不到。
 *
 * @param text  原文
 * @param ts    词
 * @param width 窗口宽度(字符),默认 220 —— 一段话的长度,不是一行的长度
 */
export function snippet(text: string, ts: string[], width = 220): string {
    if (text.length <= width) return text
    const folded = fold(text)
    // 以【第一个命中的词】为锚。找不到就给开头那一段 —— 那说明命中在标题上。
    let at = -1
    for (const t of ts) {
        const i = folded.indexOf(t)
        if (i >= 0 && (at < 0 || i < at)) at = i
    }
    if (at < 0) return text.slice(0, width).trimEnd() + '…'
    // 折叠只动了空白与大小写,长度可能与原文不同 —— 所以这个位置是【近似】的。
    // 用比例把它映射回原文,再退到最近的一个词边界,避免把一个词劈成两半。
    const approx = Math.min(text.length - 1, Math.round((at / Math.max(1, folded.length)) * text.length))
    let start = Math.max(0, approx - Math.floor(width / 3))
    while (start > 0 && !/\s/.test(text[start - 1])) start -= 1
    const end = Math.min(text.length, start + width)
    return (start > 0 ? '…' : '') + text.slice(start, end).trim() + (end < text.length ? '…' : '')
}

/**
 * 一条路由地址里【人会去搜的那些字】。
 * `/inbound/receive` → 'inbound receive' —— Tim 举的那个例子("field receiving")
 * 靠标签命中,而一个打 `/inbound/receive` 或 `receive` 的人靠这一条命中。
 */
export function hrefWords(href: string): string {
    return href.split('/').filter(Boolean).join(' ').replace(/-/g, ' ')
}
