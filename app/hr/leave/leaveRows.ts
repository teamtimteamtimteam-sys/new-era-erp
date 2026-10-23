import 'server-only'

// TABLE-EXPORT-2b-2(Tim 2026-10-22 TABLE-EXPORT-2 Q2):请假申请清单的【一份】读取 —— 页面与导出路由共用。
// 页面只画按开始日最新的 LEAVE_SHOWN 条(从前是一句不说的 .limit(300)),表上方 RowCapNotice 说出「前 N 条,共 M 条」;
// 导出路由按同一条读取、同一套筛选、同一个映射翻页取全(上限 50,000)。
// 【待审在最前】是这一页的性质(它是待办清单),在映射里做 —— 页面那 300 条与导出的全体各按同一条规则排。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { getLocale } from '@/lib/i18n/server'
import { formatDate } from '@/lib/dates'
import { mustRows } from '@/lib/db-helpers'
import type { LeaveRequestRow } from './LeaveRequestsTable'

type Client = SupabaseClient<Database>

/** 页面画多少条 —— 与转换之前同一个数。 */
export const LEAVE_SHOWN = 300

export type LeaveFilter = { status?: string; type?: string; employee?: string; from?: string; to?: string }
const KEYS = ['status', 'type', 'employee', 'from', 'to'] as const

export function leaveFilterFrom(sp: URLSearchParams | LeaveFilter): LeaveFilter {
    const out: LeaveFilter = {}
    for (const k of KEYS) { const v = sp instanceof URLSearchParams ? sp.get(k) : sp[k]; if (v) out[k] = v }
    return out
}

export function leaveQuery(f: LeaveFilter): string {
    const q = new URLSearchParams()
    for (const k of KEYS) if (f[k]) q.set(k, f[k]!)
    const s = q.toString()
    return s ? `?${s}` : ''
}

// U1-A:读 leave_requests_masked(这一页不选被遮的三列);视图的生成类型把每一列都标成可空 —— 这几列由基表的 NOT NULL 保证
export type LeaveDbRow = { id: string; code: string; employee_id: string; leave_type_code: string; start_date: string; end_date: string
                           days: number; status: string; is_exception: boolean; created_at: string }

type Q = { eq: (c: string, v: string) => Q; gte: (c: string, v: string) => Q; lte: (c: string, v: string) => Q }
function filtered<T extends Q>(qb: T, f: LeaveFilter): T {
    if (f.status) qb = qb.eq('status', f.status) as T
    if (f.type) qb = qb.eq('leave_type_code', f.type) as T
    if (f.employee) qb = qb.eq('employee_id', f.employee) as T
    if (f.from) qb = qb.gte('start_date', f.from) as T
    if (f.to) qb = qb.lte('end_date', f.to) as T
    return qb
}

export function leaveCount(supabase: Client, f: LeaveFilter) {
    return filtered(supabase.from('leave_requests_masked').select('id', { count: 'exact', head: true }).is('deleted_at', null), f)
}

export function leavePage(supabase: Client, f: LeaveFilter, from: number, to: number) {
    return filtered(supabase.from('leave_requests_masked')
        .select('id, code, employee_id, leave_type_code, start_date, end_date, days, status, is_exception, created_at')
        .is('deleted_at', null), f)
        .order('start_date', { ascending: false })
        .order('id', { ascending: true })
        .range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as LeaveDbRow[] | null }))
}

export async function shapeLeaveRows(supabase: Client, raw: LeaveDbRow[]): Promise<LeaveRequestRow[]> {
    const locale = await getLocale()
    const [empRes, typeRes] = await Promise.all([
        supabase.from('employees_masked').select('id, code, legal_name').is('deleted_at', null),
        supabase.from('leave_types').select('code, name_en, name_zh'),
    ])
    const empById = new Map((mustRows(empRes, 'employees_masked') as { id: string; code: string; legal_name: string }[]).map((e) => [e.id, e]))
    const typeByCode = new Map(mustRows(typeRes, 'leave_types').map((x) => [x.code, x]))
    // 待审在最前 —— 这是一张待办清单,不是一份档案
    const rows = [...raw].sort((a, b) => {
        if (a.status === 'pending' && b.status !== 'pending') return -1
        if (b.status === 'pending' && a.status !== 'pending') return 1
        return (b.start_date ?? '').localeCompare(a.start_date ?? '')
    })
    return rows.map((r) => {
        const e = empById.get(r.employee_id)
        const ty = typeByCode.get(r.leave_type_code)
        return {
            id: r.id,
            code: r.code,
            isException: Boolean(r.is_exception),
            employeeLabel: e ? `${e.code} — ${e.legal_name}` : '—',
            // 假期类型名的语言在服务端选好 —— locale 不过 RSC 边界
            typeLabel: ty ? (locale === 'zh' ? ty.name_zh : ty.name_en) : r.leave_type_code,
            startDate: formatDate(r.start_date, locale),
            endDate: formatDate(r.end_date, locale),
            startDateRaw: r.start_date,
            endDateRaw: r.end_date,
            days: r.days,
            status: r.status,
        }
    })
}
