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
// ── 一条【不在这一刀里】的东西,也在这里留了形状(S10)─────────────────────
//   空状态的"最近看过"与"限定在本页主语之内"要 ~21 条索引(SEARCH-0 §Q5),
//   那是 schema 改动,属于 SEARCH-2。所以这里【没有】recents 字段 ——
//   ★ 留形状不等于留一个空字段:一个永远是空数组的 recents,与"还没建"
//     在屏幕上长得一模一样,而那正是本仓库反复在修的那种谎。
//   ☞ 今天的处置写在面板的空状态里:它【说出来】还没有最近记录,而不是留白。

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

/** ① 找单据 —— **SEARCH-1 的槽,SEARCH-2 填**。 */
export type RecordHit = {
    /** 单据号,例如 PO-2026-0001。 */
    code: string
    href: string
    label: string
    moduleId: string
    moduleNavKey: string
}

export type SearchResults = {
    /** 原样回传,好让客户端丢掉过期的回包(打字比回包快时会乱序)。 */
    query: string

    // ── ① 找单据 ────────────────────────────────────────────────────────────
    // ★ SEARCH-2:**填这里,不要另起一个面板。**
    //   `built: false` 时面板画的是一句「这一半还没建」,而不是「没找到」——
    //   两者在屏幕上必须分得开(本仓库反复付账的那条:一处缺席不许被渲染成一个答案)。
    records: {
        built: boolean
        hits: RecordHit[]
        withheld: WithheldCount[]
        /** 匹配到但没画出来的条数。**不许静默截断。** */
        more: number
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
