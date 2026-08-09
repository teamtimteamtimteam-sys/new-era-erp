// app/hr/leave/page.tsx
// 请假申请列表 —— 这是一张【待办清单】,所以默认待审在最前。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import Subnav from '../Subnav'
import LeaveSubnav from './LeaveSubnav'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

type Row = {
    request_id: string
    code: string
    employee_code: string
    legal_name: string
    leave_type_code: string
    leave_type_en: string
    leave_type_zh: string
    start_date: string
    end_date: string
    days: number
    status: string
}

const STATUS_CLS: Record<string, string> = {
    pending: 'bg-amber-100 text-amber-800',
    approved: 'bg-green-100 text-green-800',
    rejected: 'bg-red-100 text-red-800',
    cancelled: 'bg-gray-100 text-gray-600',
}

export default async function LeaveRequestsPage({
    searchParams,
}: {
    searchParams: Promise<{ status?: string; type?: string; employee?: string; from?: string; to?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    let qb = supabase
        .from('leave_requests')
        .select('id, code, employee_id, leave_type_code, start_date, end_date, days, status, is_exception, created_at')
        .is('deleted_at', null)
    if (sp.status) qb = qb.eq('status', sp.status)
    if (sp.type) qb = qb.eq('leave_type_code', sp.type)
    if (sp.employee) qb = qb.eq('employee_id', sp.employee)
    if (sp.from) qb = qb.gte('start_date', sp.from)
    if (sp.to) qb = qb.lte('end_date', sp.to)

    const [reqRes, empRes, typeRes] = await Promise.all([
        qb.order('start_date', { ascending: false }).limit(300),
        supabase.from('employees').select('id, code, legal_name').is('deleted_at', null).order('code'),
        supabase.from('leave_types').select('code, name_en, name_zh').eq('is_active', true).order('sort_order'),
    ])

    const empById = new Map((mustRows(empRes)).map((e) => [e.id, e]))
    const typeByCode = new Map((mustRows(typeRes)).map((x) => [x.code, x]))
    // 待审在最前 —— 这是一张待办清单,不是一份档案
    const rows = (mustRows(reqRes)).sort((a, b) => {
        if (a.status === 'pending' && b.status !== 'pending') return -1
        if (b.status === 'pending' && a.status !== 'pending') return 1
        return (b.start_date ?? '').localeCompare(a.start_date ?? '')
    })

    const sel = 'border border-gray-300 rounded px-2 py-1 text-sm'

    return (
        <div className="p-8 max-w-6xl">
            <h1 className="text-2xl font-bold mb-4">{t('hr.title')}</h1>
            <Subnav />
            <LeaveSubnav />

            <div className="flex justify-between items-start mb-4 gap-4 flex-wrap">
                <form className="flex gap-2 flex-wrap items-end" method="get">
                    <label className="text-xs text-gray-600">
                        {t('leave.status')}
                        <select name="status" defaultValue={sp.status ?? ''} className={`block ${sel}`}>
                            <option value="">{t('leave.allStatuses')}</option>
                            {['pending', 'approved', 'rejected', 'cancelled'].map((s) => (
                                <option key={s} value={s}>{t(`leave.status_${s}`)}</option>
                            ))}
                        </select>
                    </label>
                    <label className="text-xs text-gray-600">
                        {t('leave.type')}
                        <select name="type" defaultValue={sp.type ?? ''} className={`block ${sel}`}>
                            <option value="">{t('leave.allTypes')}</option>
                            {(mustRows(typeRes)).map((x) => (
                                <option key={x.code} value={x.code}>
                                    {locale === 'zh' ? x.name_zh : x.name_en}
                                </option>
                            ))}
                        </select>
                    </label>
                    <label className="text-xs text-gray-600">
                        {t('leave.employee')}
                        <select name="employee" defaultValue={sp.employee ?? ''} className={`block ${sel}`}>
                            <option value="">{t('leave.allEmployees')}</option>
                            {(mustRows(empRes)).map((e) => (
                                <option key={e.id} value={e.id}>{e.code} — {e.legal_name}</option>
                            ))}
                        </select>
                    </label>
                    <label className="text-xs text-gray-600">
                        {t('leave.from')}
                        <input type="date" name="from" defaultValue={sp.from ?? ''} className={`block ${sel}`} />
                    </label>
                    <label className="text-xs text-gray-600">
                        {t('leave.to')}
                        <input type="date" name="to" defaultValue={sp.to ?? ''} className={`block ${sel}`} />
                    </label>
                    <button type="submit" className="border border-gray-300 rounded px-3 py-1 text-sm">
                        {t('leave.filter')}
                    </button>
                </form>
                <Link href="/hr/leave/new" className="bg-gray-900 text-white px-3 py-1.5 rounded text-sm">
                    {t('leave.recordLeave')}
                </Link>
            </div>

            {rows.length === 0 ? (
                <p className="text-gray-500">{t('leave.noRequests')}</p>
            ) : (
                <table className="w-full border-collapse text-sm">
                    <thead>
                        <tr className="bg-gray-50 text-left">
                            <th className="border border-gray-300 px-3 py-2">{t('leave.code')}</th>
                            <th className="border border-gray-300 px-3 py-2">{t('leave.employee')}</th>
                            <th className="border border-gray-300 px-3 py-2">{t('leave.type')}</th>
                            <th className="border border-gray-300 px-3 py-2">{t('leave.dates')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('leave.days')}</th>
                            <th className="border border-gray-300 px-3 py-2">{t('leave.status')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {rows.map((r) => {
                            const e = empById.get(r.employee_id)
                            const ty = typeByCode.get(r.leave_type_code)
                            return (
                                <tr key={r.id}>
                                    <td className="border border-gray-300 px-3 py-2 font-mono text-xs">
                                        <Link href={`/hr/leave/${r.id}`} className="text-blue-600 hover:underline">
                                            {r.code}
                                        </Link>
                                        {r.is_exception && (
                                            <span className="ml-2 rounded bg-purple-100 px-1.5 py-0.5 text-[10px] text-purple-800">
                                                {t('leave.exception')}
                                            </span>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        {e ? `${e.code} — ${e.legal_name}` : '—'}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        {ty ? (locale === 'zh' ? ty.name_zh : ty.name_en) : r.leave_type_code}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        {r.start_date} → {r.end_date}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 text-right font-mono">{r.days}</td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        <span className={`rounded px-2 py-0.5 text-xs ${STATUS_CLS[r.status] ?? ''}`}>
                                            {t(`leave.status_${r.status}`)}
                                        </span>
                                    </td>
                                </tr>
                            )
                        })}
                    </tbody>
                </table>
            )}
        </div>
    )
}
