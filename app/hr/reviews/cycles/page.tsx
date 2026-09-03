// app/hr/reviews/cycles/page.tsx
// 评估轮管理:建轮、开轮、关轮。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★ CONV-5:【这一页只套外壳,它不是一张登记簿】★★
// ════════════════════════════════════════════════════════════════════════════
// 本刀开工前的机械普查把它记成"有 1 张表、0 个 <th>"的异常,Tim 点名要求先
// 诊断再动。诊断结果:
//
//   ① 这一页的主体是【一叠卡片】—— 一个评估轮一个 <section>,不是一张表的行。
//      每张卡上是标题、状态徽章、期间、到期日、动作按钮,横排流式布局。
//   ② 页面里唯一的 <table> 【不是登记簿,是一个排版表格】:它嵌在每张卡里那块
//      红色「还没有评估人」的告警框内,两列 —— 左边员工、右边 SetReviewerControl。
//      它没有表头,是因为它根本不需要表头:两列各自是什么,一看就知道。
//   ③ 而那第二列是一个【会改数据的 <select>】。也就是说这张表是一个
//      【带就地动作的返修队列】,不是一份只读账簿 —— DataTable 的 render 建模不了它
//      (行级编辑态 / 脏值 / 逐行保存,见 CONV-1 §★ 那三件事)。
//
// 结论:**它既不属于 DataTable,也不属于 EditableTable。**硬套任何一个都会把
// 一个"就地补一个人"的小修口,压成一张它不是的表。所以这一页只拿 ListPage 外壳
// (标题 / 拒绝态 / 状态分支),表格与卡片一个字不动。
// ★ state 恒为 'ok' —— CycleForm(建一轮)是这一页唯一的出口,而空态分支会吞掉它。
// ════════════════════════════════════════════════════════════════════════════
// 【开轮之后,没有评估人的那些就地列出来,set_review_reviewer 就在旁边】——
// open_review_cycle 的返回值特意带着 without_reviewer,这个数是要有人处理的,
// 不该让操作员去待办看板里找。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import CycleForm from './CycleForm'
import CycleActions from './CycleActions'
import SetReviewerControl, { type EmployeeOption } from '../SetReviewerControl'
import { statusPillClass } from '../reviewShared'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'

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
        <ListPage
            title={t('hr.title')}
            maxWidth="max-w-6xl"
            actions={
                <Link href="/hr/reviews" className="text-sm text-blue-600 hover:underline">
                    {t('common.back')}
                </Link>
            }
            state={{ kind: 'ok' }}
        >
            <h2 className="text-xl font-bold mb-4">{t('reviews.cyclesTitle')}</h2>

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
        </ListPage>
    )
}
