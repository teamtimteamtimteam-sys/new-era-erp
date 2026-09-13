// lib/search/types.ts
// ════════════════════════════════════════════════════════════════════════════
// SEARCH-1 · 搜索结果的形状 —— ★【按【三件活】定形,其中一件今天返回空】★
// ════════════════════════════════════════════════════════════════════════════
//
// 【这个文件是 S2 的全部内容,所以它值得读完】
//   Tim 批准把搜索拆成两刀时,亲自点名了那次拆分的风险:
//   **「这个仓库反复为『同一件事建两遍』付账」** —— 而 SEARCH-1 先建面板、
//   SEARCH-2 再建找单据,最容易的失败方式就是 SEARCH-2 【另开一个面板】。
//
// ★【缓解只有一条,就是这个类型】★ 三件活在这里【都有自己的字段】:
//     records —— ① 找单据。**SEARCH-1 永远返回 hits: []** ,而它的字段、
//                它的 withheld、它在面板上的那一节【今天就在】。
//     pages   —— ② 找页面与动作。SEARCH-1 做活。
//     manual  —— ③ 找解释(上半:拿词搜手册)。SEARCH-1 做活。
//
// ☞ **SEARCH-2 要填的是一个【已经存在的槽】:**
//   `app/components/search/actions.ts` 里那个 `records:` 分支,
//   与 `app/components/search/SearchEntry.tsx` 里 `data-search-slot="records"`
//   那一节。两处各有一段指名 SEARCH-2 的注释。
//   **它不需要新加一个字段,不需要新加一节,更不需要第二个面板。**
//
// ── ★ SEARCH-2b(2026-09-13):recents 字段【现在才加进来】,而这是刻意的 ──────
//   SEARCH-1 写着:「这里【没有】recents 字段 —— 一个永远是空数组的 recents,
//   与『还没建』在屏幕上长得一模一样,而那正是本仓库反复在修的那种谎。」
//   ☞ 那句话在它写下的那天是对的,而**它今天不再对了**:迁移 C 建了那 22 条
//     `(updated_by, updated_at DESC)` 索引,迁移 D 建了 search_recents() ——
//     这一半**真的建起来了**,所以它可以有一个字段了。
//   ★ 而"空"这件事仍然要被说清楚:recents 为空时面板说的是
//     【因为你还没编辑过任何东西】(裁定),不是"没有结果"。
//     两者的区别今天尤其要紧 —— 实测 updated_by 填了 135/196 行,而
//     **只有 3 个操作者还在 auth.users 里**(21 个里 18 个是探针残骸),
//     所以对大多数人来说这一节【本来就是空的】。

/** 一条被扣下的结果:内容不给,存在说出来。Tim 的裁定(S9)。 */
export type WithheldCount = {
    /** MODULES 里的九个之一。★ 薪资不是模块,它住在 hr 底下 —— 所以那句话写作「HR」。 */
    moduleId: string
    /** 那个模块的文案键(MODULES 的 navKey),由调用方译成人话。 */
    moduleNavKey: string
    /** 扣下了几条。★ Tim 已裁定计数照给,全都给(SEARCH-0 §7 存了那次交换)。 */
    count: number
}

/** ② 找到的一个去处。 */
export type PageHit = {
    href: string
    /** 注册表里那条条目的 navKey —— **标签只有一份来源**。 */
    navKey: string
    /** 已经译好的标签(服务端按当前语言译,因为匹配也是按它做的)。 */
    label: string
    /** 显示在哪个模块之下。多属主的条目取声明顺序的第一个,见 actions.ts。 */
    moduleId: string
    moduleNavKey: string
}

/** ③ 手册里的一段。★ 每一条都带着它来自哪一版手册(Tim 的裁定 ③)。 */
export type ManualHit = {
    id: string
    /** PART 的整行标题 + 小节号 + 标题,拼给读者看"这段话在书的哪儿"。 */
    part: string
    number: string | null
    title: string
    /** 命中处前后的一小段原文。**英文** —— 手册只有英文,S7。 */
    snippet: string
}

/**
 * ★ SEARCH-4:一条命中带出来的【一组】关联记录 —— 按目标单据种类分组。
 *
 * ★★【为什么是一个分组行,而不是把行摊开】★★ Tim 的裁定(Q7),连理由一起:
 *   **「一个分组行答得出『这个供应商现在什么情况』,而 11 行批号答不出。」**
 *   那正是他否掉小改法(把供应商名加进 inbound 的 match_columns)时说的同一句话。
 *   ☞ 于是这里【只有一个数】,一行业务数据都没有取回来 —— `search_related()`
 *     用的是相关子查询,不是 join 回表。
 *
 * ★ 实测(2026-09-13,39 张表 320 行逐行跑了一遍):一条命中最多 **7** 组、
 *   最多 30 行;组数中位数是 **1**。不按目标种类去重的话最多是 24 组 ——
 *   「按目标单据种类去重」把最坏情况从 24 压到 7,而且它读起来才是人话
 *   (「3 个任务」,不是「1 个 owner_id、2 个 task_history、…」)。
 */
export type RelatedGroup = {
    /**
     * `document_types.key`。文案键 `search.docType.<typeKey>` 由它现拼 ——
     * ★ 后缀集合由 check-i18n 从 `db/tables/document_types.sql` 的种子**现读**,
     *   所以加一种单据时,少一句译文会当场红,而不是在屏幕上画一个空标签。
     */
    typeKey: string
    /** 你**看得见**几条。★ INVOKER —— 见 db/functions/search_related.sql 的抬头。 */
    count: number
}

/** ① 找单据 —— **SEARCH-1 的槽,SEARCH-2 填**。 */
export type RecordHit = {
    /** 单据号,例如 PO-2026-0001。 */
    code: string
    href: string
    label: string
    moduleId: string
    moduleNavKey: string
    /**
     * ★ SEARCH-4:这一条命中的关联记录,按目标单据种类分组,**按条数降序**。
     *
     * ★★【空数组说的是「这张单据没有关联记录」,不是「这一半还没建」】★★
     *   SEARCH-3 刚刚为了同一条理由删掉 `records.built` 与
     *   `search.recordsNotBuiltYet` —— 一处缺席不许被渲染成"还没做"。
     *   ⚠ 而空有两种来源,**而屏幕上那句话对两种都成立**:
     *     · 结构上就没有关联(实测今天 1 张:`bank_statements`);
     *     · 有关联的路,今天一条关联记录都没有(中位数 1 组,所以这很常见)。
     */
    related: RelatedGroup[]
}

export type SearchResults = {
    /** 原样回传,好让客户端丢掉过期的回包(打字比回包快时会乱序)。 */
    query: string

    // ── ① 找单据 ────────────────────────────────────────────────────────────
    // ★★【SEARCH-3(2026-09-13):`built` 这个布尔【删了】,而这不是顺手清扫】★★
    //   它在 SEARCH-1 那一刀里是承重的:那时这一半真的还没建,而面板必须把
    //   「还没建」与「没找到」分开说 —— 一处缺席不许被渲染成一个答案。
    //   ☞ **SEARCH-2b 之后它在两处都写死成 `true`**(actions.ts 的两个字面量),
    //     于是那条 `false` 分支【永远画不出来】,而它拖着一句文案
    //     `search.recordsNotBuiltYet`:「……is not built yet」。
    //   ★ Tim 的 U4 点名的正是这一类:**把还在说"没建"的话改掉。**
    //     而本仓库对这件事已经有一次先例,理由逐字可抄 —— SEARCH-1 删掉
    //     `home.searchNotYetBadge` / `home.searchNotYet` 时写的是:
    //     「**留着一句写着「搜索还没有建」的文案,下一个读到它的人会据此断定
    //     这件事还没做。**」这一条与那一条是同一件事。
    //   ⚠ **它删掉的不是那条区别,是那条区别的【左边】** ——「还没建」这个状态
    //     今天产生不出来了。留一个恒真的布尔 + 一条死分支,才是把区别删掉之后
    //     还留着一块牌子。
    records: {
        hits: RecordHit[]
        withheld: WithheldCount[]
        /**
         * 匹配到但没画出来的条数。**不许静默截断。**
         * ★ 它由 SQL 那一侧的 `count(*) OVER ()` 在 LIMIT 【之前】求出 ——
         *   一个 `LIMIT n+1` 的写法只答得出"还有没有更多",答不出"还有几条",
         *   于是有 50 条时它会报 1。**一个说了个小数的截断提示,与一个不提
         *   截断的结果,读起来一样错。**
         */
        more: number
    }

    // ── ★ 最近编辑过(SEARCH-2b)──────────────────────────────────────────────
    // 空查询时也有;它答的是「我上次在弄什么」,不是「我搜了什么」。
    recents: {
        hits: RecordHit[]
        /**
         * 还有几张单据表【没有】这半功能 —— 它们缺 updated_by / updated_at。
         * ★ 这个数由数据库现算(search_recents_uncovered()),**不写死**:
         *   裁定当时说的是 10,而那个 10 的分母是「31 张有行的表」;
         *   按 39 张单据表算,同一个判据给出 17。一个抄进代码的数字会在
         *   下一次加一张单据表时安静地错掉,而没有任何东西会红。
         */
        uncovered: number
    }

    // ── ② 找页面与动作 ──────────────────────────────────────────────────────
    pages: {
        hits: PageHit[]
        withheld: WithheldCount[]
        more: number
    }

    // ── ③ 找解释(上半)────────────────────────────────────────────────────
    manual: {
        hits: ManualHit[]
        more: number
        /** ★ 这一段来自哪一版手册。Tim 的裁定 ③:每一条结果都要显示它。 */
        version: string
        issued: string
    }
}
