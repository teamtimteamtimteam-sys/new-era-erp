// app/my-reviews/page.tsx
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
            <div className="p-8 max-w-lg">
                <h1 className="text-2xl font-bold mb-3">{t('reviews.myTitle')}</h1>
                <div className="rounded border border-amber-300 bg-amber-50 px-4 py-3 text-amber-900">
                    <p className="font-medium">{t('me.notLinkedTitle')}</p>
                    <p className="text-sm mt-1">{t('me.notLinkedBody')}</p>
                </div>
            </div>
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

    const renderTable = (rows: ReviewRow[]) => (
        <table className="w-full border-collapse border border-gray-300 text-sm mb-6">
            <thead className="bg-gray-100">
                <tr>
                    <th className="border border-gray-300 px-3 py-2 text-left">{t('reviews.employee')}</th>
                    <th className="border border-gray-300 px-3 py-2 text-left">{t('reviews.type')}</th>
                    <th className="border border-gray-300 px-3 py-2 text-left">{t('reviews.cycle')}</th>
                    <th className="border border-gray-300 px-3 py-2 text-left">{t('reviews.period')}</th>
                    <th className="border border-gray-300 px-3 py-2 text-left">{t('reviews.status')}</th>
                    <th className="border border-gray-300 px-3 py-2 text-left">{t('reviews.inState')}</th>
                </tr>
            </thead>
            <tbody>
                {rows.map((r) => {
                    const s = subjectByReview.get(r.id)
                    return (
                        <tr key={r.id}>
                            <td className="border border-gray-300 px-3 py-2 whitespace-nowrap">
                                <Link href={`/my-reviews/${r.id}`} className="text-blue-600 hover:underline">
                                    <span className="font-mono">{s?.employee_code ?? '—'}</span>{' '}
                                    {s?.employee_name ?? ''}
                                </Link>
                                {s?.job_title && (
                                    <span className="ml-2 text-xs text-gray-500">
                                        {s.job_title}
                                        {(locale === 'zh' ? s.department_name_zh : s.department_name_en)
                                            ? ` · ${locale === 'zh' ? s.department_name_zh : s.department_name_en}`
                                            : ''}
                                    </span>
                                )}
                            </td>
                            <td className="border border-gray-300 px-3 py-2">{t(`reviews.type_${r.review_type}`)}</td>
                            <td className="border border-gray-300 px-3 py-2">{s?.cycle_name ?? '—'}</td>
                            <td className="border border-gray-300 px-3 py-2 whitespace-nowrap font-mono text-xs">
                                {r.period_start} → {r.period_end}
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
    )

    return (
        <div className="p-8 max-w-5xl">
            <h1 className="text-2xl font-bold mb-1">{t('reviews.myTitle')}</h1>
            <p className="text-sm text-gray-600 mb-6">{t('reviews.myIntro')}</p>

            {reviews.length === 0 ? (
                <p className="text-sm text-gray-500">{t('reviews.myEmpty')}</p>
            ) : (
                <>
                    {open.length > 0 && (
                        <>
                            <h2 className="text-lg font-bold mb-2">{t('reviews.myOpen')}</h2>
                            {renderTable(open)}
                        </>
                    )}
                    {closed.length > 0 && (
                        <>
                            <h2 className="text-lg font-bold mb-2">{t('reviews.myClosed')}</h2>
                            {renderTable(closed)}
                        </>
                    )}
                </>
            )}
        </div>
    )
}
