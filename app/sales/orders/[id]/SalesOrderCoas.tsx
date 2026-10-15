// app/sales/orders/[id]/SalesOrderCoas.tsx
// MES-6b-2(2026-10-15,MES-6b Step 0 Q10 · Q14,Tim):【这张单的分析证书】—— 点名了这张单的每一张证书(批号、号、状态、签发时刻),
//   下载存下的那一份(?coa=,重算哈希)。签发与作废都不在这里:证书说的是一批,签发在那一批的页上,作废经 CFO 申请。
//   读 coa_rows(谓词 module.output.view);读不到产出批的人看到一句"受限",不是"没有证书"(一个零先问是谁读的)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { formatAuditStamp } from '@/lib/dates'
import { COA_ROW_COLUMNS, type CoaRow } from '@/app/output/coa/coaTypes'

export default async function SalesOrderCoas({ salesOrderId }: { salesOrderId: string }) {
    const t = await getTranslations()
    if (!(await can('module.output.view'))) {
        return (
            <section className="mt-8" data-section="sales-order-coa">
                <h2 className="mb-1">{t('coa.salesOrder.title')}</h2>
                <p className="text-sm text-[color:var(--brand-muted-text)]">{t('common.restricted')}</p>
            </section>
        )
    }
    const supabase = await createClient()
    const rows = mustRows(
        await supabase.from('coa_rows').select(COA_ROW_COLUMNS).eq('sales_order_id', salesOrderId).order('issued_at', { ascending: false }),
        'coa_rows') as unknown as CoaRow[]
    return (
        <section className="mt-8" data-section="sales-order-coa">
            <h2 className="mb-1">{t('coa.salesOrder.title')}</h2>
            {rows.length === 0 ? (
                <p className="text-sm text-[color:var(--brand-muted-text)]">{t('coa.salesOrder.none')}</p>
            ) : (
                <ul className="text-sm space-y-1">
                    {rows.map((r) => (
                        <li key={r.id} className="flex flex-wrap gap-x-3 gap-y-1">
                            <Link href={`/output/${r.output_batch_id}/edit`} className="app-link hover:underline">{r.batch_code}</Link>
                            <Link href={`/quality/coa/${r.id}`} className="app-link hover:underline">{r.code}</Link>
                            <span>{t('coa.status.' + r.status)}</span>
                            <span className="text-[color:var(--brand-muted-text)]">{formatAuditStamp(r.issued_at)}</span>
                            {r.has_bytes && (
                                <a className="app-link underline" href={`/output/${r.output_batch_id}/coa/pdf?coa=${encodeURIComponent(r.code)}`}
                                   target="_blank" rel="noopener noreferrer">{t('coa.download')}</a>
                            )}
                        </li>
                    ))}
                </ul>
            )}
        </section>
    )
}
