// lib/search/documentHref.ts
// ════════════════════════════════════════════════════════════════════════════
// SEARCH-5 · 「一张单据点开去哪」—— **一份实现,三个调用点**
// ════════════════════════════════════════════════════════════════════════════
//
// 【它为什么从 records.ts 里搬出来】SEARCH-2b 把这段逻辑写成 `hrefFor()`,
// 藏在 `lib/search/records.ts` 里,那时它只有一个调用点(搜索面板的命中行)。
// SEARCH-5 之后它有三个:
//   ① 搜索面板的命中行(`records.ts` 的 `toHit`);
//   ② 关联页表格里的每一行(`app/components/related/related-records.tsx`);
//   ③ ——而 ② 里 `type_list` 那一支【故意不产生链接】,见下。
// ☞ 一段被第二个调用点需要的逻辑,要么搬出来,要么被抄一遍。
//   本仓库对"抄一遍"有一长串账,所以它搬出来了。
//
// ★★【第四种 `type_list`,以及它修的那处生产缺陷】★★
//   实测(SEARCH-5,2026-09-19 线上现读):5 种单据的命中链接指向一张
//   **结构上永远 0 行**的列表 —— 目标页的 `?q=` 过滤的是【别的表】的单据号,
//   而两边前缀一个都不重叠:
//       assay_result        ASY  → /inbound   过滤 inbound_batches.code(IN-)
//       cod                 COD  → /output    过滤 output_batches.code(OUT-)
//       traceability_report TRC  → /output    同上
//       collection_chase    CHASE→ /sales/customers 过滤 customers 的五列(CUS-)
//       customer_statement  STMT → /sales/customers 同上
//   ☞ 搜到一张化验单、点开,落在一张空的进料批列表上,屏幕上写着
//     「没有符合条件的记录」。**那不是"今天恰好没有",是结构上匹配不上。**
//   ★ Tim 的 W1:它们重新指向 `/documents/<key>` —— **无主语**的那一页,
//     也就是「化验单」这一种单据自己的列表。
//
// ★★【为什么未知的 link_mode 现在【响】,而它从前【不响】】★★
//   `hrefFor()` 的旧写法是 `default: return row.route` —— 一个静默的回落。
//   ⚠ 而这一刀的破窗正好把那条回落【用上了】:窗口期间生产跑的是旧代码 +
//     新库,那 5 行已经是 `'type_list'`,旧的 switch 认不出,于是落进
//     `default` 回到未过滤的列表页。**那是这一刀窗口里唯一坏着的东西,
//     而它比今天好**(今天是过滤到 0 行的列表)。
//   ☞ 但一个静默回落本身是这个仓库反复在修的那种谎:下一次有人加第五种
//     link_mode 而忘了这里,屏幕上不会有任何东西告诉他。**所以新写法 RAISE。**
//     （旧行为不是"更宽容",它只是把错误推迟到没有人在看的时候。）

/** `document_types.link_mode` 的四个取值。真源是那张表上的 CHECK 约束。 */
export type DocumentLinkMode = 'detail' | 'list' | 'list_q' | 'type_list'

/**
 * 一张单据的落点。
 *
 * ★ `type_list` 落在 `/documents/<key>` —— 那是**这一种单据**的列表,
 *   不是这一张单据的详情页。**它们没有详情页,那正是它们是 type_list 的原因。**
 */
export function documentHref(row: {
    key: string
    route: string
    linkMode: DocumentLinkMode | string
    id: string
    code: string
}): string {
    switch (row.linkMode) {
        case 'detail':
            return `${row.route}/${row.id}`
        case 'list_q':
            // ★ 那些列表页真的读 q、而且列的就是这张表(check-search-registry 判据 ②)。
            //   改完之后只剩 4 种走这条路:inbound_batch · material · output_batch · supplier。
            return `${row.route}?q=${encodeURIComponent(row.code)}`
        case 'type_list':
            return `/documents/${row.key}`
        case 'list':
            return row.route
        default:
            // ★ 不静默回落。见文件抬头最后一段。
            throw new Error(
                `DOCUMENT_UNKNOWN_LINK_MODE|${row.linkMode}(key=${row.key})—— `
                + 'document_types.link_mode 上出现了一个这里认不出的取值。'
                + '一个静默的回落会把它画成一个【看起来能点、点了落在别处】的链接')
    }
}
