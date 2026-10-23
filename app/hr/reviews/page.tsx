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
import { mustRows, mustCount } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import { REVIEW_STATUSES, REVIEW_TYPES } from './reviewShared'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import ReviewsTable from './ReviewsTable'
import { RowCapNotice } from '@/app/components/ui/row-cap-notice'
import { REVIEWS_SHOWN, reviewsCount, reviewsFilterFrom, reviewsPage, reviewsQuery, shapeReviewRows } from './reviewsRows'
import { Button } from '@/app/components/ui/button'
import { CONTROL_SELECT } from '@/app/components/ui/control-style'

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

    // ★ TABLE-EXPORT-2b-2(Tim Q2):读取、筛选与映射搬进 reviewsRows.ts,与导出路由共用;只画最新 REVIEWS_SHOWN 份,而且说出来。
    const f = reviewsFilterFrom(sp)
    const [reviewsRes, totalRes, empRes, cycleRes] = await Promise.all([
        reviewsPage(supabase, f, 0, REVIEWS_SHOWN - 1),
        reviewsCount(supabase, f),
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

    // ★ TABLE-EXPORT-2b-1(Tim 2026-10-22 TABLE-EXPORT-2 Q10):读取失败就让这一页失败 —— 从前只取 .data、丢掉 error,
    //   一次读不到(权限、网络、一个改了名的列)在屏幕上是一张平静的「没有评估」。一次失败不是一个空集。
    const tableRows = await shapeReviewRows(supabase, mustRows(reviewsRes, 'performance_reviews_masked'))
    const total = mustCount(totalRes, 'performance_reviews_masked count')
    const employees = mustRows(empRes, 'employees') as unknown as EmployeeOpt[]
    const cycles = mustRows(cycleRes, 'review_cycles') as unknown as CycleOpt[]

    const sel = CONTROL_SELECT

    return (
        <ListPage
            title={t('hr.title')}
            maxWidth="max-w-6xl"
            actions={
                <div className="flex gap-2">
                    <Button asChild variant="outline">
                        <Link href="/hr/reviews/cycles">
                            {t('reviews.cyclesTitle')}
                        </Link>
                    </Button>
                    <Button asChild variant="outline">
                        <Link href="/hr/reviews/scale">
                            {t('reviews.scaleTitle')}
                        </Link>
                    </Button>
                </div>
            }
            state={{ kind: 'ok' }}
        >
            <form className="flex gap-2 flex-wrap items-end mb-4" method="get">
                <label className="">
                    {t('reviews.cycle')}
                    <select name="cycle" defaultValue={sp.cycle ?? ''} className={`block ${sel}`}>
                        <option value="">{t('reviews.allCycles')}</option>
                        {cycles.map((c) => (
                            <option key={c.id} value={c.id}>{c.name}</option>
                        ))}
                    </select>
                </label>
                <label className="">
                    {t('reviews.type')}
                    <select name="type" defaultValue={sp.type ?? ''} className={`block ${sel}`}>
                        <option value="">{t('reviews.allTypes')}</option>
                        {REVIEW_TYPES.map((v) => (
                            <option key={v} value={v}>{t(`reviews.type_${v}`)}</option>
                        ))}
                    </select>
                </label>
                <label className="">
                    {t('reviews.status')}
                    <select name="status" defaultValue={sp.status ?? ''} className={`block ${sel}`}>
                        <option value="">{t('reviews.allStatuses')}</option>
                        {REVIEW_STATUSES.map((v) => (
                            <option key={v} value={v}>{t(`reviews.status_${v}`)}</option>
                        ))}
                    </select>
                </label>
                <label className="">
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
                <Button variant="secondary" type="submit">
                    {t('reviews.filter')}
                </Button>
            </form>

            <RowCapNotice shown={tableRows.length} total={total} />
            <ReviewsTable rows={tableRows} empty={t('reviews.empty')} exportUrl={`/hr/reviews/export${reviewsQuery(f)}`} />
        </ListPage>
    )
}
