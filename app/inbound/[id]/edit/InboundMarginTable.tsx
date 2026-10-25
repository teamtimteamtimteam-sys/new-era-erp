'use client'

// MES-8b-1:一批进料在每一个下游产出批里的那一份 —— 份额(按投入质量)、已售、收入、成本、毛利、在库与在库成本。一行一个结点。
//   没有单位成本的结点那几格读「Not computable」,不是 0。
import { formatMoneyBare } from '@/lib/format'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xMoney, xNum, xText, type ExportCell } from '@/lib/export/cells'

export type MarginLine = {
    node_key: string; depth: number; batch_code: string; share: number; unit_cost_base: number | null; cost_incomplete: boolean
    qty_sold: number; revenue_base: number; cost_base: number | null; margin_base: number | null; on_hand: number; on_hand_at_cost_base: number | null
}

const kg = (n: number) => new Intl.NumberFormat('en-US', { maximumFractionDigits: 3 }).format(Number(n))
// 两位小数 + 千分位,不带币种 —— 币种写在列头上
const money = (n: number) => formatMoneyBare(Number(n), 'the column header names the currency')

export default function InboundMarginTable({ lines, baseCurrency, batchCode }: { lines: MarginLine[]; baseCurrency: string; batchCode: string }) {
    const t = useTranslations()
    const nc = t('inboundMargin.notComputable')
    const cell = (n: number | null, incomplete: boolean) => (n === null || incomplete ? nc : money(n))
    // TABLE-EXPORT-3b:与屏幕同一条判据 —— 没有单位成本(NULL 或 cost_incomplete)的那几格写「Not computable」这串字,不是 0。
    //   币种在列头上(本位币),于是金额写裸数 xMoney(v);重量列头写着 kg,同样写裸数。份额写成百分数(屏幕上的 ×100)。
    const cellX = (n: number | null, incomplete: boolean): ExportCell => (n === null || incomplete ? xText(nc) : xMoney(n))
    const cols: ExportableColumn<MarginLine>[] = [
        { key: 'batch', header: t('inboundMargin.colBatch'), priority: true, render: (r) => r.batch_code, exportAs: (r) => xText(r.batch_code) },
        { key: 'share', header: t('inboundMargin.colShare'), align: 'right', render: (r) => `${(Number(r.share) * 100).toFixed(2)}%`, exportAs: (r) => xNum(Number(r.share) * 100, 'pct') },
        { key: 'sold', header: t('inboundMargin.colSold'), align: 'right', render: (r) => kg(r.qty_sold), exportAs: (r) => xNum(r.qty_sold, 'qty') },
        { key: 'rev', header: t('inboundMargin.colRevenue', { ccy: baseCurrency }), align: 'right', render: (r) => money(r.revenue_base), exportAs: (r) => xMoney(r.revenue_base) },
        { key: 'cost', header: t('inboundMargin.colCost', { ccy: baseCurrency }), align: 'right', render: (r) => cell(r.cost_base, r.cost_incomplete), exportAs: (r) => cellX(r.cost_base, r.cost_incomplete) },
        { key: 'margin', header: t('inboundMargin.colMargin', { ccy: baseCurrency }), align: 'right', priority: true, render: (r) => cell(r.margin_base, r.cost_incomplete), exportAs: (r) => cellX(r.margin_base, r.cost_incomplete) },
        { key: 'onhand', header: t('inboundMargin.colOnHand'), align: 'right', render: (r) => kg(r.on_hand), exportAs: (r) => xNum(r.on_hand, 'qty') },
        { key: 'onval', header: t('inboundMargin.colOnHandAtCost', { ccy: baseCurrency }), align: 'right', render: (r) => cell(r.on_hand_at_cost_base, r.cost_incomplete), exportAs: (r) => cellX(r.on_hand_at_cost_base, r.cost_incomplete) },
    ]
    return (
        <DataTable rows={lines} columns={cols} rowKey={(r) => r.node_key} phone={{ mode: 'columns' }} empty={t('inboundMargin.noDownstream')}
                   exportSpec={{ name: 'inbound-batch-margin', title: t('inboundMargin.title'), aboutExtra: [[t('inbound.colCode'), batchCode]] }} />
    )
}
