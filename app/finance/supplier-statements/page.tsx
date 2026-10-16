// app/finance/supplier-statements/page.tsx
// MES-8a(2026-10-16,MES-0 Q79 · MES-8 Step 0 Q7–Q9,Tim):供应商对账单 —— 签发一份(选供应商与期间,先预览、后签发;必须对得上总账 2000),
//   以及签发过的每一份(SST-…,冻下来;被取代的灰掉)。员工的报销不会有对账单 —— 下拉只列供应商。
//   【门】requireFunction(FN.financeSupplierStatements) = module.finance.view;签发要 module.finance.edit。
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import { formatAmount } from '@/lib/format'
import IssuePanel from './IssuePanel'
import StatementsTable, { type StatementRow } from './StatementsTable'

type R = {
    id: string; code: string; supplier_code: string; supplier_name: string; period_start: string; period_end: string; base_currency: string
    closing_base: number; issued_at: string; superseded_at: string | null; superseded_by_code: string | null; latest_version: number | null
}

export default async function SupplierStatementsPage() {
    const denied = await requireFunction(FN.financeSupplierStatements)
    if (denied) return denied
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const [listRes, supRes, canIssue] = await Promise.all([
        supabase.from('supplier_statement_rows')
            .select('id, code, supplier_code, supplier_name, period_start, period_end, base_currency, closing_base, issued_at, superseded_at, superseded_by_code, latest_version')
            .order('issued_at', { ascending: false }).limit(300),
        supabase.from('supplier_lookup').select('id, code, legal_name').order('code'),
        can('module.finance.edit'),
    ])
    const list = mustRows(listRes, 'supplier_statement_rows') as unknown as R[]
    const suppliers = (mustRows(supRes, 'supplier_lookup') as { id: string; code: string; legal_name: string }[])
        .map((s) => ({ id: s.id, label: `${s.code} · ${s.legal_name}` }))
    const rows: StatementRow[] = list.map((r) => ({
        id: r.id, code: r.code, supplier: `${r.supplier_code} · ${r.supplier_name}`,
        period: `${formatDate(r.period_start, locale)} – ${formatDate(r.period_end, locale)}`,
        closing: formatAmount(Number(r.closing_base), r.base_currency),
        issued: formatAuditStamp(r.issued_at),
        superseded: r.superseded_at ? t('supplierStatements.supersededBy', { code: r.superseded_by_code ?? '' }) : null,
        latestVersion: r.latest_version ? `v${r.latest_version}` : t('supplierStatements.noPdfYet'),
    }))
    return (
        <ListPage title={t('supplierStatements.title')} intro={t('supplierStatements.intro')} state={{ kind: 'ok' }}>
            <IssuePanel suppliers={suppliers} canIssue={canIssue} />
            <section data-section="supplier-statements">
                <h2 className="mb-2">{t('supplierStatements.listTitle')}</h2>
                <StatementsTable rows={rows} empty={t('supplierStatements.noneIssued')} />
            </section>
        </ListPage>
    )
}
