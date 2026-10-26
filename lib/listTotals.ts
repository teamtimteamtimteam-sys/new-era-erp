// lib/listTotals.ts
// ════════════════════════════════════════════════════════════════════════════
// TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q1–Q4)· 列表的表尾合计 —— 一份形状,21 张清单共用
// ════════════════════════════════════════════════════════════════════════════
// 裁定(逐字见 docs/table-features.md):表尾合计覆盖【所有符合筛选的行】,由【数据库】算;每个币种一个合计;
// 集合里有一笔金额读者看不见,那个合计就读「受限」。冲销是净额(一对冲销加起来是 0,与总账一致)。
//
// 【库这一侧的契约】每一张清单一支 `list_totals_<清单>(<与页面同一套筛选>)`,返回同一个形状:
//     RETURNS TABLE(grp text, currency text, measure text, total numeric, restricted boolean)
//   * grp      —— 分组;平常是 ''。收付款是 'received' / 'paid'(Tim Q4:两个合计,不轧差)。
//   * currency —— 这一行合计的币种;一列固定币种、币种不在行上的(USD 结算、SGD 医疗报销)给 NULL,由页面说出那个币种。
//   * measure  —— 合计的是哪一列(页面把它映射到表的列键)。
//   * total    —— 合计;★ restricted 时恒为 NULL(看不见的数不从合计里漏出来)。
//   * restricted —— 这一行合计里有一笔(或全部)读者看不见。★「受限」用一列表示,不用【零行】表示 ——
//     零行与「本来就没有」分不开(AGENTS.md「拒绝要用哪个值表示」)。
//   每一支先 `require_permission(<页面的闸>)`:没有权限按名拒,不是 0 行。
//
// 【页面这一侧】读回来的行交给表格组件,`totalsFooterRows`(app/components/ui/list-totals.tsx)把它画成 DataTable 的表尾,
//   每个 (grp, currency) 一行。组件不加总;它画的就是库算的那个数。
// ════════════════════════════════════════════════════════════════════════════

export type ListTotal = {
    grp: string
    currency: string | null
    measure: string
    total: number | null
    restricted: boolean
}

type RawTotal = { grp: string | null; currency: string | null; measure: string | null; total: number | string | null; restricted: boolean | null }

/** 库里的行 → `ListTotal`。numeric 经 PostgREST 来是 number(大数也可能是字符串),一律转成 number。 */
export function shapeListTotals(rows: readonly RawTotal[]): ListTotal[] {
    return rows.map((r) => {
        if (r.measure == null) throw new Error('LIST_TOTALS_SHAPE|measure is null')
        const restricted = r.restricted === true
        return {
            grp: r.grp ?? '',
            currency: r.currency,
            measure: r.measure,
            total: restricted || r.total == null ? null : Number(r.total),
            restricted,
        }
    })
}
