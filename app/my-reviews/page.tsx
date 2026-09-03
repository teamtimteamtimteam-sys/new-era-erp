// app/my-reviews/page.tsx
//
// CONV-5:套 CONV-1 的两文件模板。
// ★【"没有关联到员工"那一屏走 ListPage 的 restricted 分支】—— 它渲染的是
//   CONV-0 那一份 <RefusalPage>,与"你进不来"同一个形状,因为读者要读的是
//   同一类东西:【这里为什么没有东西给我看】。不另开一条路。
// ★ 两段(手上有活 / 已了结)共用同一个表组件,与转换前那个 renderTable
//   局部函数一样 —— 它们不是两张不同的表。
// 我评的评估。【/hr 的同级,不在它下面】—— 部门经理通常一个 HR 权限码都没有,
// /hr/* 对他们全是空白;这一页靠的是 performance_reviews 的 "select as reviewer"
// 策略与 my_review_subjects 名录视图,一个模块权限都不看(同 /me 的道理)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import {
    REVIEW_COLUMNS,
    type ReviewRow,
    daysInState,
    statusPillClass,
} from '@/app/hr/reviews/reviewShared'
import { ListPage } from '@/app/components/ui/list-page'
import MyReviewsTable, { type MyReviewRow } from './MyReviewsTable'

type SubjectRow = {
    review_id: string
    employee_code: string
    employee_name: string
    job_title: string | null
    department_name_en: string | null
    department_name_zh: string | null
    cycle_name: string | null
}

export default async function MyReviewsPage() {
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    const { data: me } = await supabase.rpc('current_user_employee')
    if (!me) {
        return (
            <ListPage
                title={t('reviews.myTitle')}
                state={{
                    kind: 'restricted',
                    title: t('reviews.myTitle'),
                    statement: t('me.notLinkedTitle'),
                    hint: t('me.notLinkedBody'),
                }}
            />
        )
    }

    const [reviewsRes, subjectsRes] = await Promise.all([
        supabase
            .from('performance_reviews_masked')
            .select(REVIEW_COLUMNS)
            .eq('reviewer_employee_id', me as string)
            .neq('status', 'void')
            .order('created_at', { ascending: false }),
        supabase.from('my_review_subjects').select('*'),
    ])

    const reviews = (reviewsRes.data as unknown as ReviewRow[] | null) ?? []
    const subjects = (subjectsRes.data as unknown as SubjectRow[] | null) ?? []
    const subjectByReview = new Map(subjects.map((s) => [s.review_id, s]))

    // 手上有活的排前面:draft / self_review / submitted 是评估人的队列
    const OPEN = ['draft', 'self_review', 'submitted']
    const open = reviews.filter((r) => OPEN.includes(r.status))
    const closed = reviews.filter((r) => !OPEN.includes(r.status))

    const toRow = (r: ReviewRow): MyReviewRow => {
        const s = subjectByReview.get(r.id)
        // 职位 · 部门在服务端按 locale 拼好 —— locale 不过 RSC 边界
        const dept = locale === 'zh' ? s?.department_name_zh : s?.department_name_en
        return {
            id: r.id,
            employeeCode: s?.employee_code ?? '—',
            employeeName: s?.employee_name ?? '',
            subtitle: s?.job_title ? `${s.job_title}${dept ? ` · ${dept}` : ''}` : null,
            typeLabel: t(`reviews.type_${r.review_type}`),
            cycleName: s?.cycle_name ?? '—',
            periodStart: r.period_start,
            periodEnd: r.period_end,
            status: r.status,
            statusCls: statusPillClass(r.status),
            daysInState: daysInState(r),
        }
    }

    return (
        <ListPage
            title={t('reviews.myTitle')}
            intro={t('reviews.myIntro')}
            maxWidth="max-w-5xl"
            state={reviews.length === 0 ? { kind: 'empty', noRows: t('reviews.myEmpty') } : { kind: 'ok' }}
        >
            {open.length > 0 && (
                <>
                    <h2 className="text-lg font-bold mb-2">{t('reviews.myOpen')}</h2>
                    <MyReviewsTable rows={open.map(toRow)} />
                </>
            )}
            {closed.length > 0 && (
                <>
                    <h2 className="text-lg font-bold mb-2">{t('reviews.myClosed')}</h2>
                    <MyReviewsTable rows={closed.map(toRow)} />
                </>
            )}
        </ListPage>
    )
}
