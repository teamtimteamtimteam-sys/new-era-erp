'use client'

// MES-8b-1:一批进料在每一个下游产出批里的那一份 —— 份额(按投入质量)、已售、收入、成本、毛利、在库与在库成本。一行一个结点。
//   没有单位成本的结点那几格读「Not computable」,不是 0。
import { formatMoneyBare } from '@/lib/format'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type MarginLine = {
    node_key: string; depth: number; batch_code: string; share: number; unit_cost_base: number | null; cost_incomplete: boolean
    qty_sold: number; revenue_base: number; cost_base: number | null; margin_base: number | null; on_hand: number; on_hand_at_cost_base: number | null
}

const kg = (n: number) => new Intl.NumberFormat('en-US', { maximumFractionDigits: 3 }).format(Number(n))
// 两位小数 + 千分位,不带币种 —— 币种写在列头上
const money = (n: number) => formatMoneyBare(Number(n), 'the column header names the currency')

export default function InboundMarginTable({ lines, baseCurrency }: { lines: MarginLine[]; baseCurrency: string }) {
    const t = useTranslations()
    const nc = t('inboundMargin.notComputable')
    const cell = (n: number | null, incomplete: boolean) => (n === null || incomplete ? nc : money(n))
    const cols: Column<MarginLine>[] = [
        { key: 'batch', header: t('inboundMargin.colBatch'), priority: true, render: (r) => r.batch_code },
        { key: 'share', header: t('inboundMargin.colShare'), align: 'right', render: (r) => `${(Number(r.share) * 100).toFixed(2)}%` },
        { key: 'sold', header: t('inboundMargin.colSold'), align: 'right', render: (r) => kg(r.qty_sold) },
        { key: 'rev', header: t('inboundMargin.colRevenue', { ccy: baseCurrency }), align: 'right', render: (r) => money(r.revenue_base) },
        { key: 'cost', header: t('inboundMargin.colCost', { ccy: baseCurrency }), align: 'right', render: (r) => cell(r.cost_base, r.cost_incomplete) },
        { key: 'margin', header: t('inboundMargin.colMargin', { ccy: baseCurrency }), align: 'right', priority: true, render: (r) => cell(r.margin_base, r.cost_incomplete) },
        { key: 'onhand', header: t('inboundMargin.colOnHand'), align: 'right', render: (r) => kg(r.on_hand) },
        { key: 'onval', header: t('inboundMargin.colOnHandAtCost', { ccy: baseCurrency }), align: 'right', render: (r) => cell(r.on_hand_at_cost_base, r.cost_incomplete) },
    ]
    return <DataTable rows={lines} columns={cols} rowKey={(r) => r.node_key} phone={{ mode: 'columns' }} empty={t('inboundMargin.noDownstream')} />
}
