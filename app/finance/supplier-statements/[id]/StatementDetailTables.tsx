'use client'

// MES-8a:一份供应商对账单冻下来的四张表 —— 明细(每一笔归到这一家的总账 2000 发生)· 期末未结 · 挂账的付款 · 已收到尚未计价的收货(只有数量)。
//   收货行当时是暂定价的,标 "Provisional"(Q8)。
import { formatMoneyBare } from '@/lib/format'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import type { SstLine, SstOpenItem, SstOnAccount, SstUnpriced } from './pdf/SupplierStatementDocument'

const qty = (n: number) => new Intl.NumberFormat('en-US', { maximumFractionDigits: 4 }).format(Number(n))
// 两位小数 + 千分位,不带币种 —— 币种写在每一列的列头 / 摘要的抬头上
const money = (n: number) => formatMoneyBare(Number(n), 'the column header / summary heading names the currency')

export default function StatementDetailTables({ lines, openItems, onAccount, unpriced, baseCurrency }: {
    lines: SstLine[]; openItems: SstOpenItem[]; onAccount: SstOnAccount[]; unpriced: SstUnpriced[]; baseCurrency: string
}) {
    const t = useTranslations()
    const lineCols: Column<SstLine & { k: string }>[] = [
        { key: 'date', header: t('supplierStatements.doc.colDate'), render: (r) => r.date },
        { key: 'kind', header: t('supplierStatements.doc.colKind'), priority: true, render: (r) => (
            <span>{t('supplierStatements.doc.kind_' + r.kind)}{r.reversal && ` · ${t('supplierStatements.doc.reversal')}`}
                {r.provisional && <span className="ml-1 px-1.5 py-0.5 rounded text-xs bg-amber-100 text-amber-800" data-flag="provisional">{t('supplierStatements.doc.provisional')}</span>}</span>) },
        { key: 'doc', header: t('supplierStatements.doc.colDoc'), priority: true, render: (r) => r.doc_code },
        { key: 'entry', header: t('supplierStatements.doc.colEntry'), render: (r) => r.entry_code },
        { key: 'ccy', header: t('supplierStatements.doc.colAmountCcy'), align: 'right', render: (r) => `${r.currency} ${money(r.amount_ccy)}` },
        { key: 'base', header: t('supplierStatements.doc.colAmountBase', { ccy: baseCurrency }), align: 'right', priority: true, render: (r) => money(r.amount_base) },
    ]
    const openCols: Column<SstOpenItem & { k: string }>[] = [
        { key: 'doc', header: t('supplierStatements.doc.colDoc'), priority: true, render: (r) => r.doc_code },
        { key: 'kind', header: t('supplierStatements.doc.colKind'), render: (r) => (
            <span>{t('supplierStatements.doc.open_' + r.doc_kind)}{r.provisional && <span className="ml-1 px-1.5 py-0.5 rounded text-xs bg-amber-100 text-amber-800" data-flag="provisional">{t('supplierStatements.doc.provisional')}</span>}</span>) },
        { key: 'date', header: t('supplierStatements.doc.colDate'), render: (r) => r.doc_date },
        { key: 'open', header: t('supplierStatements.doc.colOpen'), align: 'right', priority: true, render: (r) => `${r.currency} ${money(r.open_ccy)}` },
        { key: 'days', header: t('supplierStatements.doc.colDays'), align: 'right', render: (r) => String(r.days_outstanding) },
    ]
    const accCols: Column<SstOnAccount & { k: string }>[] = [
        { key: 'code', header: t('supplierStatements.doc.colDoc'), priority: true, render: (r) => r.code },
        { key: 'date', header: t('supplierStatements.doc.colDate'), render: (r) => r.payment_date },
        { key: 'amt', header: t('supplierStatements.doc.colAmountCcy'), align: 'right', priority: true, render: (r) => `${r.currency} ${money(r.unapplied_ccy)}` },
    ]
    const unpCols: Column<SstUnpriced & { k: string }>[] = [
        { key: 'doc', header: t('supplierStatements.doc.colDoc'), priority: true, render: (r) => r.doc_code },
        { key: 'date', header: t('supplierStatements.doc.colDate'), render: (r) => r.arrival_date },
        { key: 'mat', header: t('supplierStatements.doc.colMaterial'), render: (r) => r.material_code ?? '—' },
        { key: 'qty', header: t('supplierStatements.doc.colQuantity'), align: 'right', priority: true, render: (r) => `${qty(r.quantity)} ${r.unit}` },
    ]
    return (
        <>
            <section className="mb-6" data-section="lines">
                <h2 className="mb-2">{t('supplierStatements.doc.lines')}</h2>
                <DataTable rows={lines.map((l, i) => ({ ...l, k: String(i) }))} columns={lineCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} empty={t('supplierStatements.doc.noMovement')} />
            </section>
            <section className="mb-6" data-section="open-items">
                <h2 className="mb-2">{t('supplierStatements.doc.openItems')}</h2>
                <DataTable rows={openItems.map((l, i) => ({ ...l, k: String(i) }))} columns={openCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} empty={t('supplierStatements.doc.nothingOutstanding')} />
            </section>
            {onAccount.length > 0 && (
                <section className="mb-6" data-section="on-account">
                    <h2 className="mb-2">{t('supplierStatements.doc.onAccount')}</h2>
                    <DataTable rows={onAccount.map((l, i) => ({ ...l, k: String(i) }))} columns={accCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} empty={null} />
                </section>
            )}
            <section className="mb-6" data-section="unpriced">
                <h2 className="mb-1">{t('supplierStatements.doc.unpriced')}</h2>
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('supplierStatements.doc.unpricedNote')}</p>
                <DataTable rows={unpriced.map((l, i) => ({ ...l, k: String(i) }))} columns={unpCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} empty={t('supplierStatements.doc.noUnpriced')} />
            </section>
        </>
    )
}
