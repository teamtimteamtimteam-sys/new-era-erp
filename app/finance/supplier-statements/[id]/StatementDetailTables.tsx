'use client'

// MES-8a:一份供应商对账单冻下来的四张表 —— 明细(每一笔归到这一家的总账 2000 发生)· 期末未结 · 挂账的付款 · 已收到尚未计价的收货(只有数量)。
//   收货行当时是暂定价的,标 "Provisional"(Q8)。
import { formatMoneyBare } from '@/lib/format'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xDate, xInt, xMoney, xNum, xText } from '@/lib/export/cells'
import type { SstLine, SstOpenItem, SstOnAccount, SstUnpriced } from './pdf/SupplierStatementDocument'

const qty = (n: number) => new Intl.NumberFormat('en-US', { maximumFractionDigits: 4 }).format(Number(n))
// 两位小数 + 千分位,不带币种 —— 币种写在每一列的列头 / 摘要的抬头上
const money = (n: number) => formatMoneyBare(Number(n), 'the column header / summary heading names the currency')

// ★ TABLE-EXPORT-3b:四张表各一对导出(title = 各自的 <h2>;About 写对账单编号、供应商、期间,被取代的写取代它的那一张)。
//   数全来自冻结的 jsonb 原值;每行自带币种的格 → xMoney(v, ccy),列头带本位币的格 → xMoney(v);数量 → xNum(v, 'qty', unit)。
//   这一页没有受限的格:对账单是签发时冻结的文件,屏幕上没有「受限」。
export default function StatementDetailTables({ lines, openItems, onAccount, unpriced, baseCurrency, about }: {
    lines: SstLine[]; openItems: SstOpenItem[]; onAccount: SstOnAccount[]; unpriced: SstUnpriced[]; baseCurrency: string
    /** About 表上多写的几行:哪一张对账单。 */
    about: ReadonlyArray<[string, string]>
}) {
    const t = useTranslations()
    const provisional = (on: boolean) => (on ? ` · ${t('supplierStatements.doc.provisional')}` : '')
    const lineCols: ExportableColumn<SstLine & { k: string }>[] = [
        { key: 'date', header: t('supplierStatements.doc.colDate'), render: (r) => r.date, exportAs: (r) => xDate(r.date) },
        { key: 'kind', header: t('supplierStatements.doc.colKind'), priority: true, render: (r) => (
            <span>{t('supplierStatements.doc.kind_' + r.kind)}{r.reversal && ` · ${t('supplierStatements.doc.reversal')}`}
                {r.provisional && <span className="ml-1 px-1.5 py-0.5 rounded text-xs bg-amber-100 text-amber-800" data-flag="provisional">{t('supplierStatements.doc.provisional')}</span>}</span>),
          // 冲销与「暂定价」两枚标都改变这一行的意思 → 照屏幕上这一格的字导出(标用 " · " 接上)
          exportAs: (r) => xText(t('supplierStatements.doc.kind_' + r.kind)
              + (r.reversal ? ` · ${t('supplierStatements.doc.reversal')}` : '') + provisional(r.provisional)) },
        { key: 'doc', header: t('supplierStatements.doc.colDoc'), priority: true, render: (r) => r.doc_code, exportAs: (r) => xText(r.doc_code) },
        { key: 'entry', header: t('supplierStatements.doc.colEntry'), render: (r) => r.entry_code, exportAs: (r) => xText(r.entry_code) },
        { key: 'ccy', header: t('supplierStatements.doc.colAmountCcy'), align: 'right', render: (r) => `${r.currency} ${money(r.amount_ccy)}`,
          exportAs: (r) => xMoney(r.amount_ccy, r.currency) },
        { key: 'base', header: t('supplierStatements.doc.colAmountBase', { ccy: baseCurrency }), align: 'right', priority: true, render: (r) => money(r.amount_base),
          exportAs: (r) => xMoney(r.amount_base) },
    ]
    const openCols: ExportableColumn<SstOpenItem & { k: string }>[] = [
        { key: 'doc', header: t('supplierStatements.doc.colDoc'), priority: true, render: (r) => r.doc_code, exportAs: (r) => xText(r.doc_code) },
        { key: 'kind', header: t('supplierStatements.doc.colKind'), render: (r) => (
            <span>{t('supplierStatements.doc.open_' + r.doc_kind)}{r.provisional && <span className="ml-1 px-1.5 py-0.5 rounded text-xs bg-amber-100 text-amber-800" data-flag="provisional">{t('supplierStatements.doc.provisional')}</span>}</span>),
          exportAs: (r) => xText(t('supplierStatements.doc.open_' + r.doc_kind) + provisional(r.provisional)) },
        { key: 'date', header: t('supplierStatements.doc.colDate'), render: (r) => r.doc_date, exportAs: (r) => xDate(r.doc_date) },
        { key: 'open', header: t('supplierStatements.doc.colOpen'), align: 'right', priority: true, render: (r) => `${r.currency} ${money(r.open_ccy)}`,
          exportAs: (r) => xMoney(r.open_ccy, r.currency) },
        { key: 'days', header: t('supplierStatements.doc.colDays'), align: 'right', render: (r) => String(r.days_outstanding), exportAs: (r) => xInt(r.days_outstanding) },
    ]
    const accCols: ExportableColumn<SstOnAccount & { k: string }>[] = [
        { key: 'code', header: t('supplierStatements.doc.colDoc'), priority: true, render: (r) => r.code, exportAs: (r) => xText(r.code) },
        { key: 'date', header: t('supplierStatements.doc.colDate'), render: (r) => r.payment_date, exportAs: (r) => xDate(r.payment_date) },
        { key: 'amt', header: t('supplierStatements.doc.colAmountCcy'), align: 'right', priority: true, render: (r) => `${r.currency} ${money(r.unapplied_ccy)}`,
          exportAs: (r) => xMoney(r.unapplied_ccy, r.currency) },
    ]
    const unpCols: ExportableColumn<SstUnpriced & { k: string }>[] = [
        { key: 'doc', header: t('supplierStatements.doc.colDoc'), priority: true, render: (r) => r.doc_code, exportAs: (r) => xText(r.doc_code) },
        { key: 'date', header: t('supplierStatements.doc.colDate'), render: (r) => r.arrival_date, exportAs: (r) => xDate(r.arrival_date) },
        { key: 'mat', header: t('supplierStatements.doc.colMaterial'), render: (r) => r.material_code ?? '—', exportAs: (r) => xText(r.material_code ?? '—') },
        { key: 'qty', header: t('supplierStatements.doc.colQuantity'), align: 'right', priority: true, render: (r) => `${qty(r.quantity)} ${r.unit}`,
          exportAs: (r) => xNum(r.quantity, 'qty', r.unit) },
    ]
    return (
        <>
            <section className="mb-6" data-section="lines">
                <h2 className="mb-2">{t('supplierStatements.doc.lines')}</h2>
                <DataTable rows={lines.map((l, i) => ({ ...l, k: String(i) }))} columns={lineCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} empty={t('supplierStatements.doc.noMovement')}
                    exportSpec={{ name: 'finance-supplier-statement-lines', title: t('supplierStatements.doc.lines'), aboutExtra: about }} />
            </section>
            <section className="mb-6" data-section="open-items">
                <h2 className="mb-2">{t('supplierStatements.doc.openItems')}</h2>
                <DataTable rows={openItems.map((l, i) => ({ ...l, k: String(i) }))} columns={openCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} empty={t('supplierStatements.doc.nothingOutstanding')}
                    exportSpec={{ name: 'finance-supplier-statement-open-items', title: t('supplierStatements.doc.openItems'), aboutExtra: about }} />
            </section>
            {onAccount.length > 0 && (
                <section className="mb-6" data-section="on-account">
                    <h2 className="mb-2">{t('supplierStatements.doc.onAccount')}</h2>
                    <DataTable rows={onAccount.map((l, i) => ({ ...l, k: String(i) }))} columns={accCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} empty={null}
                        exportSpec={{ name: 'finance-supplier-statement-on-account', title: t('supplierStatements.doc.onAccount'), aboutExtra: about }} />
                </section>
            )}
            <section className="mb-6" data-section="unpriced">
                <h2 className="mb-1">{t('supplierStatements.doc.unpriced')}</h2>
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('supplierStatements.doc.unpricedNote')}</p>
                <DataTable rows={unpriced.map((l, i) => ({ ...l, k: String(i) }))} columns={unpCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} empty={t('supplierStatements.doc.noUnpriced')}
                    exportSpec={{ name: 'finance-supplier-statement-unpriced-receipts', title: t('supplierStatements.doc.unpriced'), aboutExtra: about }} />
            </section>
        </>
    )
}
