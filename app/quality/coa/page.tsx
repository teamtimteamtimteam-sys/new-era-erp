// app/quality/coa/page.tsx
// MES-6b-2(2026-10-15,MES-0 Q67 · MES-6b Step 0 Q14 · Q30 · Q32,Tim):分析证书清单 —— 每一张证书:号、状态(已作废的写出谁替代了它)、
//   那一批、给谁(点了单就是客户名与单号)、签发时刻与签发人(快照里冻的那一份)、下载存下的那一份、提 CFO 作废申请(action.issue_coa)。
//   签发不在这里 —— 证书说的是一批,签发在那一批的页上(/output/[id]/edit 的证书一块)。
//   【门】requireFunction(FN.qualityCoa) = module.quality.view 与 module.output.view 都要(lib/modules.ts 的 P_COA 说了为什么)。
//   读 coa_rows(属主权限,谓词 = 证书表的读策略 module.output.view;客户名是证书的显示标签)。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { formatAuditStamp } from '@/lib/dates'
import { COA_ROW_COLUMNS, type CoaRow } from '@/app/output/coa/coaTypes'
import CoaTable, { type CoaListRow } from './CoaTable'

export default async function CoaListPage() {
    const denied = await requireFunction(FN.qualityCoa)
    if (denied) return denied
    const t = await getTranslations()
    const supabase = await createClient()
    const [res, canIssue] = await Promise.all([
        supabase.from('coa_rows').select(COA_ROW_COLUMNS).order('issued_at', { ascending: false }),
        can('action.issue_coa'),
    ])
    const coas = mustRows(res, 'coa_rows') as unknown as CoaRow[]
    const rows: CoaListRow[] = coas.map((c) => ({
        id: c.id,
        code: c.code,
        status: c.status,
        statusLabel: t('coa.status.' + c.status),
        batchId: c.output_batch_id,
        batchCode: c.batch_code,
        issuedTo: c.sales_order_code ? `${c.customer_name ?? '—'} · ${c.sales_order_code}` : t('coa.panel.noOrder'),
        issued: formatAuditStamp(c.issued_at) ?? '—',
        issuedAt: c.issued_at,
        issuedBy: c.issued_by_name ? `${c.issued_by_name}${c.issued_by_position ? `, ${c.issued_by_position}` : ''}` : '',
        replacedBy: c.replaced_by_code,
        hasBytes: c.has_bytes,
        openRequestLabel: c.open_request_label,
    }))
    return (
        <ListPage title={t('coa.list.title')} intro={t('coa.list.intro')} state={{ kind: 'ok' }}>
            <CoaTable rows={rows} empty={t('coa.list.empty')} canIssue={canIssue} />
        </ListPage>
    )
}
