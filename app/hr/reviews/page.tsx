// app/hr/reviews/page.tsx
// 绩效评估列表。可按评估轮 / 类型 / 状态 / 员工筛;每行给出评估人与
// 【在当前状态里停了多久】—— 一份在 submitted 里躺了三周的评估就是一件待办。
// 读遮蔽伴生视图:没有 module.hr.view + data.view_reviews 的人在这里是零行,
// 薪酬列在视图里就被遮掉,页面不再各自判断。
//
// CONV-5:套 CONV-1 的两文件模板。同目录下的 GoalsEditor 是可编辑网格,它挂在
// /hr/reviews/[id](详情页),【不在这一页上】—— CONV-3 §⑧-10 点名要核实的四张
// 之一,本刀按 import 核实后确认:这一页是纯只读账簿。
// ★ state 恒为 'ok' —— 筛选表单与右侧两个入口(评估轮/评分档)都是真实出口。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import {
    REVIEW_COLUMNS,
    REVIEW_STATUSES,
    REVIEW_TYPES,
    type ReviewRow,
    daysInState,
    statusPillClass,
} from './reviewShared'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import ReviewsTable, { type ReviewsTableRow } from './ReviewsTable'

type EmployeeOpt = { id: string; code: string; legal_name: string }
type CycleOpt = { id: string; name: string }

export default async function ReviewsPage({
    searchParams,
}: {
    searchParams: Promise<{ cycle?: string; type?: string; status?: string; employee?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

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

    const tableRows: ReviewsTableRow[] = reviews.map((r) => {
        const emp = empById.get(r.employee_id)
        const rev = r.reviewer_employee_id ? empById.get(r.reviewer_employee_id) : null
        return {
            id: r.id,
            employeeCode: emp?.code ?? '—',
            employeeLabel: emp?.legal_name ?? '',
            typeLabel: t(`reviews.type_${r.review_type}`),
            cycleName: r.cycle_id ? (cycleById.get(r.cycle_id) ?? '—') : '—',
            periodStart: r.period_start,
            periodEnd: r.period_end,
            reviewerCode: rev?.code ?? null,
            reviewerName: rev?.legal_name ?? null,
            status: r.status,
            statusCls: statusPillClass(r.status),
            daysInState: daysInState(r),
        }
    })

    return (
        <ListPage
            title={t('hr.title')}
            maxWidth="max-w-6xl"
            actions={
                <div className="flex gap-2">
                    <Link href="/hr/reviews/cycles" className="border border-gray-300 px-3 py-1.5 rounded hover:bg-gray-50 text-sm">
                        {t('reviews.cyclesTitle')}
                    </Link>
                    <Link href="/hr/reviews/scale" className="border border-gray-300 px-3 py-1.5 rounded hover:bg-gray-50 text-sm">
                        {t('reviews.scaleTitle')}
                    </Link>
                </div>
            }
            state={{ kind: 'ok' }}
        >
            <form className="flex gap-2 flex-wrap items-end mb-4" method="get">
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

            <ReviewsTable rows={tableRows} empty={t('reviews.empty')} />
        </ListPage>
    )
}
