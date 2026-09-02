// app/hr/claims/page.tsx
// 医疗报销列表。settlement_state 来自 medical_claim_status —— 它从【已过账的付款】
// 推导"钱到底付了没有",而不是相信报销单自己的状态列。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

const CLS: Record<string, string> = {
    submitted: 'bg-amber-100 text-amber-800',
    approved: 'bg-blue-100 text-blue-800',
    rejected: 'bg-red-100 text-red-800',
    expense_raised: 'bg-purple-100 text-purple-800',
    awaiting_payment_run: 'bg-blue-100 text-blue-800',
    part_paid: 'bg-purple-100 text-purple-800',
    paid: 'bg-green-100 text-green-800',
}

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

    return (
        <div className="p-8 max-w-6xl">
            <h1 className="text-2xl font-bold mb-4">{t('hr.title')}</h1>
            <div className="flex justify-between items-end mb-4 gap-4 flex-wrap">
                <form method="get" className="flex gap-2 flex-wrap items-end">
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
                <Link href="/hr/claims/new" className="bg-gray-900 text-white px-3 py-1.5 rounded text-sm">
                    {t('claims.record')}
                </Link>
            </div>

            {rows.length === 0 ? <p className="text-gray-500">{t('claims.none')}</p> : (
                <table className="w-full border-collapse text-sm">
                    <thead>
                        <tr className="bg-gray-50 text-left">
                            <th className="border border-gray-300 px-3 py-2">{t('claims.code')}</th>
                            <th className="border border-gray-300 px-3 py-2">{t('leave.employee')}</th>
                            <th className="border border-gray-300 px-3 py-2">{t('claims.date')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('claims.amount')}</th>
                            <th className="border border-gray-300 px-3 py-2">{t('claims.state')}</th>
                            <th className="border border-gray-300 px-3 py-2">{t('claims.expense')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {rows.map((r) => (
                            <tr key={r.claim_id}>
                                <td className="border border-gray-300 px-3 py-2 font-mono text-xs">
                                    <Link href={`/hr/claims/${r.claim_id}`} className="text-blue-600 hover:underline">{r.code}</Link>
                                </td>
                                <td className="border border-gray-300 px-3 py-2">{r.employee_code} — {r.legal_name}</td>
                                <td className="border border-gray-300 px-3 py-2">{r.claim_date}</td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                    {Number(r.amount_sgd).toFixed(2)} SGD
                                </td>
                                <td className="border border-gray-300 px-3 py-2">
                                    <span className={`rounded px-2 py-0.5 text-xs ${CLS[r.settlement_state ?? ''] ?? ''}`}>
                                        {t(`claims.state_${r.settlement_state}`)}
                                    </span>
                                </td>
                                <td className="border border-gray-300 px-3 py-2 font-mono text-xs">
                                    {r.expense_code ?? '—'}
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}
        </div>
    )
}
