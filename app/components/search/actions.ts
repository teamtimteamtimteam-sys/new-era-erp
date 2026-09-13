'use server'

// app/components/search/actions.ts
// ════════════════════════════════════════════════════════════════════════════
// SEARCH-1 · 一次搜索的【服务端那一半】—— 三件活在这一支里汇合
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么在服务端,而不是把索引发到浏览器里】两条,第二条更硬:
//   ① 手册索引是 101 段正文。发到客户端 = 每一页的包里都背着整本手册;
//   ② ★★ **计数必须在服务端算。** S9 的那句话是「Finance 里还有 3 条,你没有
//      权限看」。要数出那个 3,就得拿【这个人看不见的那些条目的标签】去比对
//      用户打的字 —— 而把那些标签发到浏览器里,等于把"内容不给"这一半也给了。
//      **存在说出来,内容不给**,只有在服务端数才做得到。
//
// ── 权限:只有一个求值器 ────────────────────────────────────────────────────
//   `allows()`(lib/modules.ts),而 `scripts/check-permission-predicate.mjs` 的
//   判据 ① 禁止任何别处再写一份。本文件里没有任何一句 `perms.includes(...)`,
//   每一条可见性都走 allows()。
//
// ── ★ 多属主的条目,那句话里报哪个模块 ──────────────────────────────────────
//   一条条目可以同属几个模块(/inbound 属采购 · 库存 · 运营)。它被扣下时
//   要报一个模块名,而【报哪个】必须是一条写下来的规则,不是一次随手的选择:
//   **取声明顺序的第一个属主。**
//   ☞ 为什么不像 `activeModuleForPath` 那样"取第一个他进得去的":那支函数答的是
//     「我现在站在哪」,而它的前提是【这个人已经打开了这一页】。这里恰恰相反 ——
//     这条条目被扣下,正因为他一个属主都进不去,那条规则在这里【没有答案】。
//     所以取 modules[0],并且把这句话写在这里。
//
// ── ★ 一个【没有量的数】,照直说 ────────────────────────────────────────────
//   本支每次调用读一次 `getMyPermissions()`(React cache 在一次请求内只打一次库)。
//   **一次搜索在生产上要多久,本刀没有量,而且今天量不了** ——
//   SEARCH-0 §4.2 记着理由:那 21 张单据表今天合计 196 行,`EXPLAIN` 出来全是
//   Seq Scan,那次测量量的是【形状】不是【成本】。报一个毫秒数就是编一个数。
//   ☞ job ② 与 job ③ 【一行数据库都不读】(注册表在内存里、手册索引在内存里),
//     所以今天这支的成本 = 一次权限查询。job ① 进来那天,这句话要重写。
import { getMyPermissions } from '@/lib/permissions'
import { getTranslations } from '@/lib/i18n/server'
import { FUNCTIONS, MODULES, allows } from '@/lib/modules'
import { MANUAL_PASSAGES, MANUAL_VERSION, MANUAL_ISSUED } from '@/data/manualIndex.generated'
import { terms, matchesAll, snippet, hrefWords } from '@/lib/search/match'
import type { SearchResults, PageHit, ManualHit, WithheldCount } from '@/lib/search/types'

/**
 * 一次显示几条。
 *
 * ★【这两个数是【挑】出来的,不是量出来的 —— 说白】★
 *   SEARCH-0 §8 把"一次显示几条"列在【下一轮】的问题里,因为它挂在
 *   「一次搜索到底查几张表」底下,而那一条要等 Q3。所以这里不假装它有依据:
 *   8 与 5 是为了让面板在 390px 上不用滚太久而挑的。
 *   ☞ 而挑一个数的代价【必须说出来】:超出的部分由 `more` 带回去,
 *     面板把它画成「还有 N 条没画出来」。**不许静默截断** ——
 *     一份看不见截断的结果,读起来就是"只有这么多"。
 */
const PAGE_LIMIT = 8
const MANUAL_LIMIT = 5

/** 模块 id → 它的文案键。MODULES 是唯一的一份来源。 */
const moduleNavKey = (id: string) => MODULES.find((m) => m.id === id)?.navKey ?? id

/** 把逐条的"被扣下"卷成【按模块的计数】,顺序跟着 MODULES 的顺序走。 */
function rollUp(withheldModuleIds: string[]): WithheldCount[] {
    const n = new Map<string, number>()
    for (const id of withheldModuleIds) n.set(id, (n.get(id) ?? 0) + 1)
    return MODULES.filter((m) => n.has(m.id)).map((m) => ({
        moduleId: m.id,
        moduleNavKey: m.navKey,
        count: n.get(m.id) as number,
    }))
}

export async function searchEverything(query: string): Promise<SearchResults> {
    const ts = terms(query)
    const t = await getTranslations()

    const empty: SearchResults = {
        query,
        records: { built: false, hits: [], withheld: [], more: 0 },
        pages: { hits: [], withheld: [], more: 0 },
        manual: { hits: [], more: 0, version: MANUAL_VERSION, issued: MANUAL_ISSUED },
    }
    // 【空查询不是一次搜索】—— 不查库、不扫手册。面板的空状态自己会说话。
    if (ts.length === 0) return empty

    // ── 权限。★ 失败就抛 ★ ────────────────────────────────────────────────
    //   `getMyPermissions()` 自己就是这么写的,理由整段写在 lib/permissions.ts:
    //   一次查询失败被读成"零权限",会让每一条结果都变成「你没有权限看」——
    //   **一次瞬时故障与一次蓄意收权在屏幕上长得一模一样。**
    //   这里【不接】那个异常,让它落到错误边界上。
    const perms = await getMyPermissions()

    // ══ ② 找页面与动作 ══════════════════════════════════════════════════════
    // 匹配两样:译好的标签,以及地址里的词(`/inbound/receive` → "inbound receive")。
    // 两样都算命中 —— 一个记得住路径的人和一个只记得名字的人要落在同一条上。
    // 排序同上:**标签命中的排在只有地址命中的前面**,两组各自按注册表顺序
    //(而注册表顺序【就是】菜单顺序 —— lib/modules.ts 里写着这句话)。
    const allowedHits: PageHit[] = []
    const allowedByHrefOnly: PageHit[] = []
    const withheldModules: string[] = []
    for (const fn of FUNCTIONS) {
        const label = t(fn.navKey)
        const byLabel = matchesAll(label, ts)
        if (!byLabel && !matchesAll(label + ' ' + hrefWords(fn.href), ts)) continue
        if (allows(fn.permission, perms)) {
            ;(byLabel ? allowedHits : allowedByHrefOnly).push({
                href: fn.href,
                navKey: fn.navKey,
                label,
                moduleId: fn.modules[0],
                moduleNavKey: moduleNavKey(fn.modules[0]),
            })
        } else {
            // ★ 内容不给,存在说出来。取声明顺序的第一个属主 —— 见抬头。
            withheldModules.push(fn.modules[0])
        }
    }

    // ══ ③ 找解释(上半:拿词搜手册)══════════════════════════════════════════
    // ★【两种语言搜的都是【英文手册】】★ Tim 的 Q8 裁定。它的后果他没有说,
    //   而面板必须处理:一个用中文搜的人在这一节里【什么都匹配不到】,
    //   那读起来是"搜索坏了"。所以面板在这一节的抬头上常年画一句
    //   `search.manualEnglishOnly`(两个文案文件里都有),**不管有没有命中**。
    // 【手册【不】过权限】它是一本给所有人读的操作手册,不是数据。
    //   一段解释"入库怎么走"对一个没有 inbound 权限的人仍然是对的、也仍然该读得到。
    // ★【排序:只有一条规则,而它不是"相关度"】★
    //   **标题命中的排在正文命中的前面**,两组各自按文档顺序。
    //   理由:一个把这些词写进【标题】的小节,答的就是这个问题;正文里顺带提过
    //   一句的不是。☞ 而**除此之外的排序【不在这一刀里】** —— SEARCH-0 §8 把
    //   「结果怎么排序、一次显示几条、三类结果怎么混排」列在【下一轮】,
    //   因为它们挂在「一次搜索到底查几张表」底下,而那一条要等 Q3(前缀表)。
    //   **所以这里不假装有一套评分。** 一条规则,写下来,够用。
    const titleFirst = MANUAL_PASSAGES.filter((p) => matchesAll(p.title, ts))
    const bodyOnly = MANUAL_PASSAGES.filter((p) =>
        !matchesAll(p.title, ts) && matchesAll(p.title + ' ' + p.text, ts))
    const manualMatches = [...titleFirst, ...bodyOnly]
    const manualHits: ManualHit[] = manualMatches.slice(0, MANUAL_LIMIT).map((p) => ({
        id: p.id,
        part: p.part,
        number: p.number,
        title: p.title,
        snippet: snippet(p.text || p.title, ts),
    }))

    const ranked = [...allowedHits, ...allowedByHrefOnly]

    return {
        query,
        // ══ ① 找单据 —— ★ SEARCH-2 的槽 ★ ══════════════════════════════════
        // 【为什么是 built: false 而不是一个空数组】一个空数组读起来是"没找到",
        // 而事实是"这一半还没建"。**一处缺席不许被渲染成一个答案** ——
        // 这是本仓库反复付账的那一条,而这里是它最容易再发生一次的地方。
        //
        // ★★ SEARCH-2:**把 hits/withheld/more 填在这里,把 built 改成 true。**
        //   那一刀要的三样东西(document_types 前缀表 · pg_trgm + GIN ·
        //   ~21 条 updated_at/updated_by 索引)全部是迁移,所以它们不在本刀里
        //   —— SEARCH-0 §5 的分刀理由。**但槽在这里,面板那一节也在,
        //   所以那一刀是【填】,不是【再开一个面板】。**
        records: { built: false, hits: [], withheld: [], more: 0 },
        pages: {
            hits: ranked.slice(0, PAGE_LIMIT),
            withheld: rollUp(withheldModules),
            more: Math.max(0, ranked.length - PAGE_LIMIT),
        },
        manual: {
            hits: manualHits,
            more: Math.max(0, manualMatches.length - MANUAL_LIMIT),
            version: MANUAL_VERSION,
            issued: MANUAL_ISSUED,
        },
    }
}
