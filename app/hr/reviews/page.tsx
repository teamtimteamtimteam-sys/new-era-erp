// app/hr/reviews/page.tsx
// 绩效评估列表。可按评估轮 / 类型 / 状态 / 员工筛;每行给出评估人与
// 【在当前状态里停了多久】—— 一份在 submitted 里躺了三周的评估就是一件待办。
// 读遮蔽伴生视图:没有 module.hr.view + data.view_reviews 的人在这里是零行,
// 薪酬列在视图里就被遮掉,页面不再各自判断。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../Subnav'
import {
    REVIEW_COLUMNS,
    REVIEW_STATUSES,
    REVIEW_TYPES,
    type ReviewRow,
    daysInState,
    statusPillClass,
} from './reviewShared'

type EmployeeOpt = { id: string; code: string; legal_name: string }
type CycleOpt = { id: string; name: string }

export default async function ReviewsPage({
    searchParams,
}: {
    searchParams: Promise<{ cycle?: string; type?: string; status?: string; employee?: string }>
}) {
    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    let qb = supabase.from('performance_reviews_masked').select(REVIEW_COLUMNS)
    if (sp.cycle) qb = qb.eq('cycle_id', sp.cycle)
    if (sp.type) qb = qb.eq('review_type', sp.type)
    if (sp.status) qb = qb.eq('status', sp.status)
    if (sp.employee) qb = qb.eq('employee_id', sp.employee)

    const [reviewsRes, empRes, cycleRes] = await Promise.all([
        qb.order('created_at', { ascending: false }).limit(200),
        supabase
            .from('employees')
            .select('id, code, legal_name')
            .is('deleted_at', null)
            .order('code'),
        supabase
            .from('review_cycles')
            .select('id, name')
            .is('deleted_at', null)
            .order('period_start', { ascending: false }),
    ])

    const reviews = (reviewsRes.data as unknown as ReviewRow[] | null) ?? []
    const employees = (empRes.data as unknown as EmployeeOpt[] | null) ?? []
    const cycles = (cycleRes.data as unknown as CycleOpt[] | null) ?? []
    const empById = new Map(employees.map((e) => [e.id, e]))
    const cycleById = new Map(cycles.map((c) => [c.id, c.name]))

    const sel = 'border border-gray-300 rounded px-2 py-1 text-sm'

    return (
        <div className="p-8 max-w-6xl">
            <h1 className="text-2xl font-bold mb-4">{t('hr.title')}</h1>
            <Subnav />

            <div className="flex justify-between items-start mb-4 gap-4 flex-wrap">
                <form className="flex gap-2 flex-wrap items-end" method="get">
                    <label className="text-xs text-gray-600">
                        {t('reviews.cycle')}
                        <select name="cycle" defaultValue={sp.cycle ?? ''} className={`block ${sel}`}>
                            <option value="">{t('reviews.allCycles')}</option>
                            {cycles.map((c) => (
                                <option key={c.id} value={c.id}>{c.name}</option>
                            ))}
                        </select>
                    </label>
                    <label className="text-xs text-gray-600">
                        {t('reviews.type')}
                        <select name="type" defaultValue={sp.type ?? ''} className={`block ${sel}`}>
                            <option value="">{t('reviews.allTypes')}</option>
                            {REVIEW_TYPES.map((v) => (
                                <option key={v} value={v}>{t(`reviews.type_${v}`)}</option>
                            ))}
                        </select>
                    </label>
                    <label className="text-xs text-gray-600">
                        {t('reviews.status')}
                        <select name="status" defaultValue={sp.status ?? ''} className={`block ${sel}`}>
                            <option value="">{t('reviews.allStatuses')}</option>
                            {REVIEW_STATUSES.map((v) => (
                                <option key={v} value={v}>{t(`reviews.status_${v}`)}</option>
                            ))}
                        </select>
                    </label>
                    <label className="text-xs text-gray-600">
                        {t('reviews.employee')}
                        <select name="employee" defaultValue={sp.employee ?? ''} className={`block ${sel}`}>
                            <option value="">{t('reviews.allEmployees')}</option>
                            {employees.map((e) => (
                                <option key={e.id} value={e.id}>
                                    {e.code} · {e.legal_name}
                                </option>
                            ))}
                        </select>
                    </label>
                    <button type="submit" className="border border-gray-300 rounded px-3 py-1 text-sm">
                        {t('reviews.filter')}
                    </button>
                </form>
                <div className="flex gap-2">
                    <Link
                        href="/hr/reviews/cycles"
                        className="border border-gray-300 px-3 py-1.5 rounded hover:bg-gray-50 text-sm"
                    >
                        {t('reviews.cyclesTitle')}
                    </Link>
                    <Link
                        href="/hr/reviews/scale"
                        className="border border-gray-300 px-3 py-1.5 rounded hover:bg-gray-50 text-sm"
                    >
                        {t('reviews.scaleTitle')}
                    </Link>
                </div>
            </div>

            {reviews.length === 0 ? (
                <p className="text-sm text-gray-500">{t('reviews.empty')}</p>
            ) : (
                <table className="w-full border-collapse border border-gray-300 text-sm">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('reviews.employee')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('reviews.type')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('reviews.cycle')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('reviews.period')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('reviews.reviewer')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('reviews.status')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('reviews.inState')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {reviews.map((r) => {
                            const emp = empById.get(r.employee_id)
                            const rev = r.reviewer_employee_id ? empById.get(r.reviewer_employee_id) : null
                            return (
                                <tr key={r.id}>
                                    <td className="border border-gray-300 px-3 py-2 whitespace-nowrap">
                                        <Link href={`/hr/reviews/${r.id}`} className="text-blue-600 hover:underline">
                                            <span className="font-mono">{emp?.code ?? '—'}</span>{' '}
                                            {emp?.legal_name ?? ''}
                                        </Link>
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">{t(`reviews.type_${r.review_type}`)}</td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        {r.cycle_id ? cycleById.get(r.cycle_id) ?? '—' : '—'}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 whitespace-nowrap font-mono text-xs">
                                        {r.period_start} → {r.period_end}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 whitespace-nowrap">
                                        {rev ? (
                                            <>
                                                <span className="font-mono">{rev.code}</span> {rev.legal_name}
                                            </>
                                        ) : (
                                            <span className="text-red-700">{t('reviews.noReviewer')}</span>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        <span className={'inline-block rounded px-2 py-0.5 text-xs ' + statusPillClass(r.status)}>
                                            {t(`reviews.status_${r.status}`)}
                                        </span>
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 whitespace-nowrap text-gray-600">
                                        {t('hr.daysRemaining', { n: daysInState(r) })}
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
