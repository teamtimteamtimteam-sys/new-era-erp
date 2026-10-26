'use client'
// ════════════════════════════════════════════════════════════════════════════
// TABLE-FEATURES-2(Tim 2026-10-25 Q1)· 库算的合计 → DataTable 的表尾行(每个 grp × 币种一行)
// ════════════════════════════════════════════════════════════════════════════
// 形状与来历见 lib/listTotals.ts 抬头。这里只画,不加总 —— DataTable 的 footer 交给我们的 `rendered`(这一屏的行)
// 【故意不用】:裁定要的是所有符合筛选的行,不是这一页(data-table.tsx FooterRow 抬头:服务端算的合计是被认可的用法)。
//
// 一格的画法:
//   * restricted → 「受限」(Refusal,带一句为什么)—— 「0.00」与「受限」不是一回事(AGENTS.md xmodule 那一节);
//   * 否则 → 两位小数;币种写在这一行的标签上(「合计 · SGD」),所以格子里用 formatMoneyBare。
// 收付款的 grp 'received' / 'paid' 各有自己的标签(Tim 2026-10-26 Q4)。
import * as React from 'react'
import type { FooterRow } from '@/app/components/ui/data-table'
import { Refusal } from '@/app/components/ui/refusal'
import { formatMoneyBare } from '@/lib/format'
import type { ListTotal } from '@/lib/listTotals'

type T = (key: string, values?: Record<string, string | number>) => string

/**
 * @param totals   库读回来的合计(lib/listTotals.ts 的 shapeListTotals)。
 * @param columns  measure → 表的列键。没列进来的 measure 不画(并当场按名拒绝,免得一个合计悄悄消失)。
 * @param fixedCurrency 这一列币种固定、库里给 NULL 时,标签上说出来的那个币种(例如列头写着的 USD / SGD);不给就只写「合计」。
 */
export function totalsFooterRows(
    totals: readonly ListTotal[],
    columns: Readonly<Record<string, string>>,
    t: T,
    fixedCurrency?: string,
): FooterRow[] {
    const groups = new Map<string, { grp: string; currency: string | null; cells: Record<string, React.ReactNode> }>()
    for (const x of totals) {
        const col = columns[x.measure]
        if (!col) throw new Error(`LIST_TOTALS_UNKNOWN_MEASURE|${x.measure}`)
        const k = `${x.grp}|${x.currency ?? ''}`
        const g = groups.get(k) ?? { grp: x.grp, currency: x.currency, cells: {} }
        g.cells[col] = x.restricted
            ? <Refusal why={t('table.totals.restrictedWhy')}>{t('common.restricted')}</Refusal>
            : formatMoneyBare(x.total, '表尾这一行的标签写着币种')
        groups.set(k, g)
    }
    return [...groups.entries()].map(([key, g]) => {
        const ccy = g.currency ?? fixedCurrency ?? null
        const label = g.grp === 'received' ? t('table.totals.received', { ccy: ccy ?? '' })
            : g.grp === 'paid' ? t('table.totals.paid', { ccy: ccy ?? '' })
            : ccy ? t('table.totals.totalCcy', { ccy }) : t('table.totals.total')
        return {
            key: `totals:${key}`,
            label: <span title={t('table.totals.note')}>{label}</span>,
            cells: g.cells,
            className: 'bg-gray-100 font-bold',
        }
    })
}
