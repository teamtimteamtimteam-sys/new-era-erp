import 'server-only'

// TABLE-EXPORT-2b-2(Tim 2026-10-22 TABLE-EXPORT-2 Q2):绩效评估清单的【一份】读取 —— 页面与导出路由共用。
// 页面只画最新的 REVIEWS_SHOWN 份(从前是一句不说的 .limit(200)),表上方 RowCapNotice 说出「前 N 份,共 M 份」;
// 导出路由按同一条读取、同一套筛选、同一个映射翻页取全(上限 50,000)。
// 读遮蔽伴生视图 performance_reviews_masked(见页面抬头);排序在建立时刻之后补 id —— 翻页要一个【唯一】的次序。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatDate } from '@/lib/dates'
import { mustRows } from '@/lib/db-helpers'
import { REVIEW_COLUMNS, type ReviewRow, daysInState, statusPillClass } from './reviewShared'
import type { ReviewsTableRow } from './ReviewsTable'

type Client = SupabaseClient<Database>

/** 页面画多少份 —— 与转换之前同一个数。 */
export const REVIEWS_SHOWN = 200

export type ReviewsFilter = { cycle?: string; type?: string; status?: string; employee?: string }
const KEYS = ['cycle', 'type', 'status', 'employee'] as const

export function reviewsFilterFrom(sp: URLSearchParams | ReviewsFilter): ReviewsFilter {
    const out: ReviewsFilter = {}
    for (const k of KEYS) { const v = sp instanceof URLSearchParams ? sp.get(k) : sp[k]; if (v) out[k] = v }
    return out
}

export function reviewsQuery(f: ReviewsFilter): string {
    const q = new URLSearchParams()
    for (const k of KEYS) if (f[k]) q.set(k, f[k]!)
    const s = q.toString()
    return s ? `?${s}` : ''
}

type Q = { eq: (c: string, v: string) => Q }
function filtered<T extends Q>(qb: T, f: ReviewsFilter): T {
    if (f.cycle) qb = qb.eq('cycle_id', f.cycle) as T
    if (f.type) qb = qb.eq('review_type', f.type) as T
    if (f.status) qb = qb.eq('status', f.status) as T
    if (f.employee) qb = qb.eq('employee_id', f.employee) as T
    return qb
}

export function reviewsCount(supabase: Client, f: ReviewsFilter) {
    return filtered(supabase.from('performance_reviews_masked').select('id', { count: 'exact', head: true }), f)
}

export function reviewsPage(supabase: Client, f: ReviewsFilter, from: number, to: number) {
    return filtered(supabase.from('performance_reviews_masked').select(REVIEW_COLUMNS), f)
        .order('created_at', { ascending: false })
        .order('id', { ascending: true })
        .range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as ReviewRow[] | null }))
}

export async function shapeReviewRows(supabase: Client, reviews: ReviewRow[]): Promise<ReviewsTableRow[]> {
    const t = await getTranslations()
    const locale = await getLocale()
    const [empRes, cycleRes] = await Promise.all([
        supabase.from('employees_masked').select('id, code, legal_name').is('deleted_at', null),
        supabase.from('review_cycles').select('id, name').is('deleted_at', null),
    ])
    const empById = new Map((mustRows(empRes, 'employees_masked') as { id: string; code: string; legal_name: string }[]).map((e) => [e.id, e]))
    const cycleById = new Map(mustRows(cycleRes, 'review_cycles').map((c) => [c.id, c.name]))
    return reviews.map((r) => {
        const emp = empById.get(r.employee_id)
        const rev = r.reviewer_employee_id ? empById.get(r.reviewer_employee_id) : null
        return {
            id: r.id,
            employeeCode: emp?.code ?? '—',
            employeeLabel: emp?.legal_name ?? '',
            typeLabel: t(`reviews.type_${r.review_type}`),
            cycleName: r.cycle_id ? (cycleById.get(r.cycle_id) ?? '—') : '—',
            periodStart: formatDate(r.period_start, locale),
            periodEnd: formatDate(r.period_end, locale),
            periodStartRaw: r.period_start,
            periodEndRaw: r.period_end,
            reviewerCode: rev?.code ?? null,
            reviewerName: rev?.legal_name ?? null,
            status: r.status,
            statusCls: statusPillClass(r.status),
            daysInState: daysInState(r),
        }
    })
}
