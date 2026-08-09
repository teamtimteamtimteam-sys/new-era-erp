// app/hr/reviews/cycles/page.tsx
// 评估轮管理:建轮、开轮、关轮。
// 【开轮之后,没有评估人的那些就地列出来,set_review_reviewer 就在旁边】——
// open_review_cycle 的返回值特意带着 without_reviewer,这个数是要有人处理的,
// 不该让操作员去待办看板里找。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import Subnav from '../../Subnav'
import CycleForm from './CycleForm'
import CycleActions from './CycleActions'
import SetReviewerControl, { type EmployeeOption } from '../SetReviewerControl'
import { statusPillClass } from '../reviewShared'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

type CycleRow = {
    id: string
    name: string
    period_start: string
    period_end: string
    due_date: string
    status: string
    notes: string | null
}

type CycleReview = {
    id: string
    employee_id: string
    cycle_id: string | null
    status: string
    reviewer_employee_id: string | null
}

export default async function ReviewCyclesPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const [cycleRes, reviewRes, empRes] = await Promise.all([
        supabase
            .from('review_cycles')
            .select('id, name, period_start, period_end, due_date, status, notes')
            .is('deleted_at', null)
            .order('period_start', { ascending: false }),
        supabase
            .from('performance_reviews_masked')
            .select('id, employee_id, cycle_id, status, reviewer_employee_id')
            .not('cycle_id', 'is', null)
            .neq('status', 'void'),
        supabase
            .from('employees')
            .select('id, code, legal_name, employment_status')
            .is('deleted_at', null)
            .order('code'),
    ])

    // 读不到就必须炸:渲染成"还没有周期"会诱使人再开一轮,而开轮会给每名员工
    // 再生成一条评估 —— 唯一的护栏只是名称唯一索引。
    const cycles = mustRows(cycleRes, 'review_cycles') as unknown as CycleRow[]
    const reviews = (reviewRes.data as unknown as CycleReview[] | null) ?? []
    const employees = (empRes.data as unknown as (EmployeeOption & { employment_status: string })[] | null) ?? []
    const empById = new Map(employees.map((e) => [e.id, e]))
    const assignable = employees.filter((e) => e.employment_status !== 'separated')

    const byCycle = new Map<string, CycleReview[]>()
    for (const r of reviews) {
        if (!r.cycle_id) continue
        const list = byCycle.get(r.cycle_id) ?? []
        list.push(r)
        byCycle.set(r.cycle_id, list)
    }

    return (
        <div className="p-8 max-w-6xl">
            <h1 className="text-2xl font-bold mb-4">{t('hr.title')}</h1>
            <Subnav />

            <div className="flex items-baseline justify-between mb-4">
                <h2 className="text-xl font-bold">{t('reviews.cyclesTitle')}</h2>
                <Link href="/hr/reviews" className="text-sm text-blue-600 hover:underline">
                    {t('common.back')}
                </Link>
            </div>

            <CycleForm />

            {cycles.length === 0 ? (
                <p className="text-sm text-gray-500">{t('reviews.noCycles')}</p>
            ) : (
                <div className="space-y-4">
                    {cycles.map((c) => {
                        const rs = byCycle.get(c.id) ?? []
                        const unsubmitted = rs.filter((r) => r.status === 'draft' || r.status === 'self_review')
                        const noReviewer = rs.filter(
                            (r) =>
                                r.reviewer_employee_id === null &&
                                !['approved', 'acknowledged'].includes(r.status)
                        )
                        return (
                            <section key={c.id} className="rounded border border-gray-200 p-4">
                                <div className="flex items-center gap-3 flex-wrap mb-1">
                                    <h3 className="font-bold">{c.name}</h3>
                                    <span className={'inline-block rounded px-2 py-0.5 text-xs ' + statusPillClass(c.status === 'open' ? 'self_review' : c.status === 'closed' ? 'acknowledged' : 'draft')}>
                                        {t(`reviews.cycleStatus_${c.status}`)}
                                    </span>
                                    <span className="font-mono text-xs text-gray-500">
                                        {c.period_start} → {c.period_end}
                                    </span>
                                    <span className="text-xs text-gray-500">
                                        {t('reviews.dueDate')}: <span className="font-mono">{c.due_date}</span>
                                    </span>
                                    <CycleActions cycleId={c.id} status={c.status} />
                                </div>
                                {rs.length > 0 && (
                                    <p className="text-xs text-gray-600 mb-2">
                                        {t('reviews.cycleCounts', {
                                            0: rs.length,
                                            1: unsubmitted.length,
                                        })}
                                    </p>
                                )}

                                {/* 没有评估人的,就地补 —— 不需要去待办看板里找 */}
                                {noReviewer.length > 0 && (
                                    <div className="mt-2 rounded border border-red-200 bg-red-50 p-3">
                                        <p className="text-sm font-medium text-red-800 mb-2">
                                            {t('reviews.noReviewerList', { 0: noReviewer.length })}
                                        </p>
                                        <table className="w-full text-sm">
                                            <tbody>
                                                {noReviewer.map((r) => {
                                                    const emp = empById.get(r.employee_id)
                                                    return (
                                                        <tr key={r.id}>
                                                            <td className="py-1 pr-4 whitespace-nowrap">
                                                                <Link
                                                                    href={`/hr/reviews/${r.id}`}
                                                                    className="text-blue-700 hover:underline"
                                                                >
                                                                    <span className="font-mono">{emp?.code ?? '—'}</span>{' '}
                                                                    {emp?.legal_name ?? ''}
                                                                </Link>
                                                            </td>
                                                            <td className="py-1">
                                                                <SetReviewerControl
                                                                    reviewId={r.id}
                                                                    employees={assignable}
                                                                    currentReviewerId={null}
                                                                    subjectEmployeeId={r.employee_id}
                                                                />
                                                            </td>
                                                        </tr>
                                                    )
                                                })}
                                            </tbody>
                                        </table>
                                    </div>
                                )}
                            </section>
                        )
                    })}
                </div>
            )}
        </div>
    )
}
