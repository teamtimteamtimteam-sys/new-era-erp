// lib/search/records.ts
// ════════════════════════════════════════════════════════════════════════════
// SEARCH-2b · job ① 的服务端那一半 —— 找单据,以及「最近编辑过」
// ════════════════════════════════════════════════════════════════════════════
//
// 【这个文件填的是一个【已经存在的槽】】lib/search/types.ts 的 records 字段、
// actions.ts 的 records 分支、SearchEntry.tsx 的 data-search-slot="records"
// 那一节 —— 三处 SEARCH-1 都留好了,并且各写了一段指名 SEARCH-2 的注释。
// **这一刀是填,不是再开一个面板。**
//
// ── ★ 匹配面与排序【不在这里】,在数据库里 ─────────────────────────────────
//   `search_documents()` 一支 SQL 函数按 document_types 现算要查哪些表。
//   为什么不在这里循环 39 次:排序是【跨表】的(精确 code 要排在别的表的标签
//   命中前面),而跨表排序在这里做,就得先把 39 张表的命中【全部】取回来,
//   包括那些只用来排序、最后被截掉的 —— 那正是 S9 禁止的那件事的另一种走法。
//
// ── ★★ 被扣下的那个计数,为什么要第二支函数 ────────────────────────────────
//   `search_documents()` 是 INVOKER:他能看见哪几条,由 RLS 策略自己回答。
//   而"他看不见的还有几条"RLS 按构造答不了 —— 那些行根本不进他的视野。
//   所以 `search_documents_withheld()` 是 SECURITY DEFINER,而且**只返回数**:
//   S9 的裁定是「存在说出来,内容不给」。
//   ☞ 它只数【模块扣下的】(T4)。一个人持有某一类的模块闸却仍看不见某几行
//     (归属、行别),那几行**不计** —— 迁移 D 的抬头写着这个界限,以及它
//     少报的那一格(assay_results / contracts 的按行析取)。
//
// ── ★ 「最近编辑过」覆盖不到的那些表,由这里【现算】,不写死一个数 ──────────
//   裁定当时写的是「10 张未覆盖的表在屏幕上点名」,而那个 10 的分母是
//   **31 张有行的表**。单据种类是 **39 张表**,于是同一个判据给出的是 **17**。
//   ☞ 所以屏幕上那一行的数【从登记表 join 目录现算】。写死 10 或 17 都会在
//     下一次加一张单据表时安静地错掉,而没有任何东西会红。
import { createClient } from '@/lib/supabase/server'
import { mustRows, mustOne } from '@/lib/db-helpers'
import { FUNCTIONS, MODULES } from '@/lib/modules'
import type { RecordHit, RelatedGroup, WithheldCount } from '@/lib/search/types'

/**
 * 一次显示几条。
 *
 * ★★【SEARCH-4:8 → 5,而这是一次【裁定重开】,不是一次实现细节】★★
 *   上限 8 是在「一条命中 = 一行」的时候定的(SEARCH-2 §3)。SEARCH-4 让每条
 *   命中带上它的关联分组,于是同一个 8 变成另一个体量 —— 实测一条命中最多 7 组:
 *     · 8 条命中都满载 = **56 行分组行**;
 *     · 不按目标种类去重的话,一条命中最多 24 组 ⇒ 8 条 = **192 行**。那不是一个下拉。
 *   ☞ 两层各有自己的上限,而且它们不是同一个数:
 *     **外层(命中)5;内层(关联)按目标种类分组、每组一行、不展开行。**
 *     5 × 7 = 35,而组数中位数是 1。
 *   ⚠ job ② 的上限仍是 8 —— 两个数此前同源,现在分家了,因为只有 job ① 的
 *     那一行会长高。
 */
export const RECORD_LIMIT = 5
/** 「最近编辑过」显示几条 —— 裁定:5 条。 */
export const RECENTS_LIMIT = 5

type DbError = { message: string; code?: string } | null
type WithheldRow = { key: string; route: string; n: number }

type Row = {
    key: string
    id: string
    code: string
    label: string | null
    route: string
    link_mode: string
    updated_at: string | null
    total?: number
}

/**
 * route → 属主模块。
 *
 * ★【规则与 job ② 逐字相同:取声明顺序的第一个属主】★ 不另立一条。
 * ☞ 而它要多走一步:`/sales/shipments` **在注册表里没有条目**(实测 ——
 *   那条路径只有 `[id]/page.tsx`,没有列表页,所以它从来不是一个菜单去处)。
 *   于是按路径段向上找,找到 `/sales`。**这一步是必要的,不是防御性的**:
 *   40 个 route 里今天恰好有一个是这种形状,而闸会盯着这句话继续成立。
 */
function moduleForRoute(route: string): { moduleId: string; moduleNavKey: string } {
    let path = route
    for (;;) {
        const fn = FUNCTIONS.find((f) => f.href === path)
        if (fn) {
            const id = fn.modules[0]
            return { moduleId: id, moduleNavKey: moduleNavKey(id) }
        }
        const cut = path.lastIndexOf('/')
        if (cut <= 0) break
        path = path.slice(0, cut)
    }
    // 走到这里说明 route 连它的一级段都不在注册表里 —— 那是闸该抓的事
    // (scripts/check-search-registry.mjs 的判据 ①),不是这里该猜的事。
    throw new Error(`document_types.route 在导航注册表里找不到属主模块: ${route}`)
}

function moduleNavKey(id: string): string {
    const m = MODULES.find((x) => x.id === id)
    if (!m) throw new Error(`MODULES 里没有 ${id}`)
    return m.navKey
}

/** link_mode → 这条单据点开去哪。三种,登记表里声明,由闸核对。 */
function hrefFor(row: Row): string {
    switch (row.link_mode) {
        case 'detail':
            return `${row.route}/${row.id}`
        case 'list_q':
            // ★ 没有详情页的那些:落在列表页上,并把 code 带进 ?q= ——
            //   实测那些列表页读 q 并按 code.ilike 过滤,所以这是一个【可用的落点】,
            //   不是一个"差不多的地方"。
            return `${row.route}?q=${encodeURIComponent(row.code)}`
        default:
            return row.route
    }
}

function toHit(row: Row, related: RelatedGroup[] = []): RecordHit {
    const { moduleId, moduleNavKey: navKey } = moduleForRoute(row.route)
    return {
        code: row.code,
        href: hrefFor(row),
        // 标签截 60(裁定)。没有标签就不给标签 —— 不拿别的东西顶上。
        label: row.label ? row.label.slice(0, 60) : '',
        moduleId,
        moduleNavKey: navKey,
        related,
    }
}

/**
 * ① 找单据。
 *
 * ★【查询失败就抛】★ 与 getMyPermissions 同一条理由,而这里更要紧:
 *   一次失败若被读成"没找到",面板会把"搜索坏了"画成"库里没有这张单据"——
 *   而一个记得自己昨天开过 PO-2026-0007 的人会以为它被删了。
 */
export async function searchRecords(query: string): Promise<{
    hits: RecordHit[]
    withheld: WithheldCount[]
    more: number
}> {
    const supabase = await createClient()
    const [found, held] = await Promise.all([
        supabase.rpc('search_documents', { p_query: query, p_limit: RECORD_LIMIT }),
        supabase.rpc('search_documents_withheld', { p_query: query }),
    ])
    const rows = mustRows(found as { data: Row[] | null; error: DbError }, 'search_documents')
    const heldRows = mustRows(
        held as { data: WithheldRow[] | null; error: DbError }, 'search_documents_withheld')
    // ★ 不许静默截断:total 是【截断之前】的条数,由 SQL 那一侧 count(*) OVER ()
    //   给出。一个 LIMIT n+1 的写法只答得出"还有没有更多",答不出"还有几条"。
    const total = rows.length > 0 ? Number(rows[0].total ?? rows.length) : 0
    // ★ SEARCH-4:关联记录【挂在命中上,不产生命中】(Q6)——
    //   搜 "Acme" 的结果仍然只有一条命中(实测 total = 1),变的是那一条命中带着什么。
    //   ☞ 所以这一趟在【命中截断之后】才跑:至多 RECORD_LIMIT 次,而不是 total 次。
    const related = await Promise.all(rows.map((r) => relatedFor(supabase, r)))
    return {
        hits: rows.map((r, i) => toHit(r, related[i])),
        withheld: rollUpWithheld(heldRows),
        more: Math.max(0, total - rows.length),
    }
}

type RelatedRow = { target_key: string; n: number }

/**
 * 一条命中的关联记录,按目标单据种类分组。
 *
 * ★【为什么不在这里做第二层过滤】`search_related()` 是 INVOKER —— 他看得见
 *   几条由 RLS 自己回答。在这里再判一次就是把同一条规则写第二遍,而本仓库
 *   为"两份实现在写下来那天一致、之后悄悄分开"付过四次账。
 *
 * ★【一类整类被模块闸扣下时,这里数出 0,那一组就不出现 —— 而这是对的】
 *   顶层那一次 `search_documents_withheld()` 已经把"这一类你能不能看"说过一遍;
 *   在关联层再报一次数,同一件事会在屏幕上出现两次,而两个数不一样
 *   (顶层数的是**匹配面**,这里数的是**关联面**),读起来像矛盾。
 */
async function relatedFor(
    supabase: Awaited<ReturnType<typeof createClient>>,
    row: Row,
): Promise<RelatedGroup[]> {
    const res = await supabase.rpc('search_related', { p_key: row.key, p_id: row.id })
    // ★ 失败就抛 —— 与 searchRecords 同一条理由,而这里更容易读错:
    //   一次失败若被读成空数组,屏幕上会说「这张单据没有关联记录」,
    //   而那是一句【关于数据的断言】,不是一句关于查询的断言。
    const rows = mustRows(res as { data: RelatedRow[] | null; error: DbError }, 'search_related')
    return rows.map((r) => ({ typeKey: r.target_key, count: Number(r.n) }))
}

/** 被扣下的按模块合并 —— 与 job ② 的 rollUp 同一个形状,同一条规则。 */
function rollUpWithheld(rows: WithheldRow[]): WithheldCount[] {
    const byModule = new Map<string, number>()
    for (const r of rows) {
        const { moduleId } = moduleForRoute(r.route)
        byModule.set(moduleId, (byModule.get(moduleId) ?? 0) + Number(r.n))
    }
    return MODULES.filter((m) => byModule.has(m.id)).map((m) => ({
        moduleId: m.id,
        moduleNavKey: m.navKey,
        count: byModule.get(m.id) as number,
    }))
}

/**
 * 「最近编辑过」—— `updated_by = auth.uid()`,按 updated_at DESC 取 5 条。
 *
 * ★【看不见的行静默消失】★ 裁定。而这里【不加第二层过滤】—— RLS 就是这么
 *   工作的,再写一遍就是把同一条规则写第二遍(本仓库反复付账的那一条)。
 *
 * ★★【它今天很可能是空的,而那不是坏了】★★ 实测(SEARCH-2 六轮):
 *   updated_by 填了 135/196 行,但**只有 3 个操作者还在 auth.users 里**
 *   (21 个里 18 个是探针残骸),admin 一个人占 95 行。
 *   ☞ 所以空状态那一句要说【因为你还没编辑过任何东西】,不是"没有结果"。
 */
export async function recentRecords(): Promise<{ hits: RecordHit[]; uncovered: number }> {
    const supabase = await createClient()
    const [recent, uncovered] = await Promise.all([
        supabase.rpc('search_recents', { p_limit: RECENTS_LIMIT }),
        supabase.rpc('search_recents_uncovered'),
    ])
    // ★ 走 mustRows / mustOne —— 一次失败必须【失败】。这一节尤其要紧:
    //   它本来就【经常是空的】(见下),所以一次静默失败在屏幕上与"你还没编辑过
    //   任何东西"长得一模一样,而那是本仓库爆炸半径最大的那种谎。
    const uncoveredCount = mustOne(
        uncovered as { data: number | null; error: DbError }, 'search_recents_uncovered')
    if (uncoveredCount === null) {
        throw new Error('查询失败(search_recents_uncovered): 成功返回却没有数 —— '
            + '这支函数是 count(*),它不可能没有答案')
    }
    return {
        // ★ 「最近编辑过」不带关联分组:那一节答的是「我上次在弄什么」,
        //   一叠计数挂在它下面只会把它读成第二份搜索结果。裁定 Q7 说的是
        //   【命中】带关联,而 recents 不是命中。
        hits: mustRows(recent as { data: Row[] | null; error: DbError }, 'search_recents')
            .map((r) => toHit(r)),
        uncovered: uncoveredCount,
    }
}
