// app/hr/claims/page.tsx
// 医疗报销列表。settlement_state 来自 medical_claim_status —— 它从【已过账的付款】
// 推导"钱到底付了没有",而不是相信报销单自己的状态列。
//
// CONV-5:套 CONV-1 的两文件模板。
// ★ state 恒为 'ok' —— 这一页的筛选表单是真实出口,筛空了不能连表单一起藏。
//   见 docs/list-page-template.md §⑩-3(这一刀 15 张页面共用同一条判据)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import ClaimsTable, { type ClaimRow } from './ClaimsTable'

export default async function ClaimsPage({
    searchParams,
}: { searchParams: Promise<{ status?: string; employee?: string; year?: string }> }) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    let qb = supabase.from('medical_claim_status').select('*')
    if (sp.employee) qb = qb.eq('employee_id', sp.employee)
    if (sp.year) qb = qb.eq('claim_year', Number(sp.year))
    const [rowsRes, empRes] = await Promise.all([
        qb.order('claim_date', { ascending: false }).limit(300),
        supabase.from('employees').select('id, code, legal_name').is('deleted_at', null).order('code'),
    ])
    let rows = mustRows(rowsRes)
    if (sp.status) rows = rows.filter((r) => r.settlement_state === sp.status)

    const sel = 'border border-gray-300 rounded px-2 py-1 text-sm'

    const tableRows: ClaimRow[] = rows.map((r) => ({
        claimId: r.claim_id as string,
        code: r.code as string,
        employeeLabel: `${r.employee_code} — ${r.legal_name}`,
        claimDate: r.claim_date as string,
        amountSgd: Number(r.amount_sgd).toFixed(2),
        settlementState: (r.settlement_state ?? '') as string,
        expenseCode: (r.expense_code ?? '—') as string,
    }))

    return (
        <ListPage
            title={t('hr.title')}
            maxWidth="max-w-6xl"
            actions={
                <Link href="/hr/claims/new" className="bg-gray-900 text-white px-3 py-1.5 rounded text-sm">
                    {t('claims.record')}
                </Link>
            }
            state={{ kind: 'ok' }}
        >
            <form method="get" className="flex gap-2 flex-wrap items-end mb-4">
                <label className="text-xs text-gray-600">{t('claims.state')}
                    <select name="status" defaultValue={sp.status ?? ''} className={`block ${sel}`}>
                        <option value="">{t('leave.allStatuses')}</option>
                        {['submitted','approved','rejected','expense_raised','part_paid','paid'].map((s) => (
                            <option key={s} value={s}>{t(`claims.state_${s}`)}</option>
                        ))}
                    </select>
                </label>
                <label className="text-xs text-gray-600">{t('leave.employee')}
                    <select name="employee" defaultValue={sp.employee ?? ''} className={`block ${sel}`}>
                        <option value="">{t('leave.allEmployees')}</option>
                        {(mustRows(empRes)).map((e) => (
                            <option key={e.id} value={e.id}>{e.code} — {e.legal_name}</option>
                        ))}
                    </select>
                </label>
                <label className="text-xs text-gray-600">{t('claims.year')}
                    <input type="number" name="year" defaultValue={sp.year ?? ''} className={`block ${sel} w-24`} /></label>
                <button type="submit" className="border border-gray-300 rounded px-3 py-1 text-sm">{t('leave.filter')}</button>
            </form>

            <ClaimsTable rows={tableRows} empty={t('claims.none')} />
        </ListPage>
    )
}
