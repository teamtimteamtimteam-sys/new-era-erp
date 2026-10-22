// app/finance/supplier-statements/page.tsx
// MES-8a(2026-10-16,MES-0 Q79 · MES-8 Step 0 Q7–Q9,Tim):供应商对账单 —— 签发一份(选供应商与期间,先预览、后签发;必须对得上总账 2000),
//   以及签发过的每一份(SST-…,冻下来;被取代的灰掉)。员工的报销不会有对账单 —— 下拉只列供应商。
//   【门】requireFunction(FN.financeSupplierStatements) = module.finance.view;签发要 module.finance.edit。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows, mustCount } from '@/lib/db-helpers'
import { RowCapNotice } from '@/app/components/ui/row-cap-notice'
import { STATEMENTS_SHOWN, statementCount, statementPage, shapeStatementRows } from './statementRows'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import IssuePanel from './IssuePanel'
import StatementsTable, { type StatementRow } from './StatementsTable'

export default async function SupplierStatementsPage() {
    const denied = await requireFunction(FN.financeSupplierStatements)
    if (denied) return denied
    const t = await getTranslations()
    const supabase = await createClient()
    const [listRes, supRes, canIssue] = await Promise.all([
        // ★ TABLE-EXPORT-2a(Tim Q2):读取与映射搬进 statementRows.ts,与导出路由共用;只画最近 STATEMENTS_SHOWN 份,而且说出来。
        statementPage(supabase, 0, STATEMENTS_SHOWN - 1),
        supabase.from('supplier_lookup').select('id, code, legal_name').order('code'),
        can('module.finance.edit'),
    ])
    const total = mustCount(await statementCount(supabase), 'supplier_statement_rows count')
    const list = mustRows(listRes, 'supplier_statement_rows')
    const suppliers = (mustRows(supRes, 'supplier_lookup') as { id: string; code: string; legal_name: string }[])
        .map((s) => ({ id: s.id, label: `${s.code} · ${s.legal_name}` }))
    const rows: StatementRow[] = await shapeStatementRows(list)
    return (
        <ListPage title={t('supplierStatements.title')} intro={t('supplierStatements.intro')} state={{ kind: 'ok' }}>
            <IssuePanel suppliers={suppliers} canIssue={canIssue} />
            <section data-section="supplier-statements">
                <h2 className="mb-2">{t('supplierStatements.listTitle')}</h2>
                <RowCapNotice shown={rows.length} total={total} />
                <StatementsTable rows={rows} empty={t('supplierStatements.noneIssued')} />
            </section>
        </ListPage>
    )
}
