import 'server-only'

// TABLE-EXPORT-2b-2(Tim 2026-10-22 TABLE-EXPORT-2 Q2):请假申请清单的【一份】读取 —— 页面与导出路由共用。
// 页面只画按开始日最新的 LEAVE_SHOWN 条(从前是一句不说的 .limit(300)),表上方 RowCapNotice 说出「前 N 条,共 M 条」;
// 导出路由按同一条读取、同一套筛选、同一个映射翻页取全(上限 50,000)。
// 【待审在最前】是这一页的性质(它是待办清单),在映射里做 —— 页面那 300 条与导出的全体各按同一条规则排。
// ★ TABLE-FEATURES-1(Tim 2026-10-25 Q12):上面那一句的做法是错的,已改。从前先按开始日取最新 300 条、【再】在 JS 里把待审抬到最前,
//   于是一张开始日较早、落在 300 条之外的待审申请【永远不出现】—— 待办清单漏掉的恰恰是等得最久的那几张。
//   现在「待审在最前」在数据库里做、在截断【之前】做:先取待审(开始日新的在前),剩下的位置再由非待审按同一顺序填满
//   (leavePage 的两段读取);映射不再重排。页面、计数与导出走同一条读取,所以三者是同一个顺序。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { getLocale } from '@/lib/i18n/server'
import { formatDate } from '@/lib/dates'
import { mustRows } from '@/lib/db-helpers'
import type { LeaveRequestRow } from './LeaveRequestsTable'

import { parseListSort, applyListSort, setSortParams, type ListSort } from '@/lib/listSort'

type Client = SupabaseClient<Database>

/**
 * ★ TABLE-FEATURES-1(Tim 2026-10-25 Q9):可排的列 —— 列键 → `leave_requests_masked` 上的列(lib/listSort.ts 的规矩)。
 *   员工那一格是查出来再拼的、假期类型名是从 leave_types 查出来的 —— 都不可排。日期那一格按开始日排。
 * ★ Q12:默认的 `pending`(待审在最前)不是一列,而是一个两段的次序(见 leavePage);它不对应任何表头,所以默认时没有表头亮着。
 *   读者点了某一列,就是那一列的普通数据库排序,待审不再抬头。
 */
export const LEAVE_SORT = { code: 'code', dates: 'start_date', days: 'days', status: 'status' } as const
type LeaveColumnKey = keyof typeof LEAVE_SORT
export type LeaveSortKey = LeaveColumnKey | 'pending'
const LEAVE_SORT_KEYS: LeaveSortKey[] = ['pending', ...(Object.keys(LEAVE_SORT) as LeaveColumnKey[])]
const LEAVE_SORT_DEFAULT: ListSort<LeaveSortKey> = { key: 'pending', dir: 'desc' }
/** 今天的次序(开始日新的在前,平局按 id)—— 待审一段与非待审一段各自按它排,列排序也以它作平局键。 */
const LEAVE_TIEBREAK = [['start_date', 'desc'], ['id', 'asc']] as const

/** 页面画多少条 —— 与转换之前同一个数。 */
export const LEAVE_SHOWN = 300

export type LeaveFilter = { status?: string; type?: string; employee?: string; from?: string; to?: string; sort: ListSort<LeaveSortKey> }
const KEYS = ['status', 'type', 'employee', 'from', 'to'] as const
type LeaveSearch = { status?: string; type?: string; employee?: string; from?: string; to?: string; sort?: string; dir?: string }

export function leaveFilterFrom(sp: URLSearchParams | LeaveSearch): LeaveFilter {
    const get = (k: keyof LeaveSearch) => (sp instanceof URLSearchParams ? sp.get(k) : sp[k]) || undefined
    // TABLE-FEATURES-1 Q9:排序与筛选读同一份参数
    const out: LeaveFilter = { sort: parseListSort({ sort: get('sort'), dir: get('dir') }, LEAVE_SORT_KEYS, LEAVE_SORT_DEFAULT) }
    for (const k of KEYS) { const v = get(k); if (v) out[k] = v }
    return out
}

export function leaveQuery(f: LeaveFilter): string {
    const q = new URLSearchParams()
    for (const k of KEYS) if (f[k]) q.set(k, f[k]!)
    // TABLE-FEATURES-1 Q9:导出按当前顺序取全
    setSortParams(q, f.sort)
    return `?${q.toString()}`
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

const LEAVE_SELECT = 'id, code, employee_id, leave_type_code, start_date, end_date, days, status, is_exception, created_at'

function leaveRows(supabase: Client, f: LeaveFilter) {
    return filtered(supabase.from('leave_requests_masked').select(LEAVE_SELECT).is('deleted_at', null), f)
}

type LeavePageResult = { error: { message: string } | null; data: LeaveDbRow[] | null }

/**
 * 取第 from..to 行(含两端),页面取 0..LEAVE_SHOWN-1,导出路由按 1,000 一批翻页取全 —— 同一个函数,所以同一个顺序。
 * ★ TABLE-FEATURES-1 Q12:默认次序是两段 —— [0, P) 是待审(P = 筛选之内待审的条数),[P, 全部) 是其余;两段各按开始日新的在前、平局 id。
 *   一个区间可能只落在一段里,也可能跨两段;跨的时候拼起来。待审先于截断取,所以 300 条之外不会再藏着一张待审。
 *   计数(leaveCount)不变:两段加起来就是筛选之内的全部,RowCapNotice 的「前 N 条,共 M 条」照旧成立。
 */
export async function leavePage(supabase: Client, f: LeaveFilter, from: number, to: number): Promise<LeavePageResult> {
    const done = ({ data, error }: { data: unknown; error: { message: string } | null }): LeavePageResult =>
        ({ error, data: data as LeaveDbRow[] | null })
    if (f.sort.key !== 'pending') {
        // 读者点了一列:那一列的普通数据库排序(ORDER BY 在 .range 之前),平局按今天的次序
        return applyListSort(leaveRows(supabase, f), f.sort as ListSort<LeaveColumnKey>, LEAVE_SORT, LEAVE_TIEBREAK)
            .range(from, to)
            .then(done)
    }
    if (to < from) return { error: null, data: [] }
    // 两段各按今天的次序:开始日新的在前,平局按 id
    const ordered = <T,>(q: T) => applyListSort(q, { key: 'dates', dir: 'desc' } as ListSort<LeaveColumnKey>, LEAVE_SORT, LEAVE_TIEBREAK)

    // ① 筛选之内有几张待审(状态筛选不是 pending 时,两个 eq 相斥,自然是 0)
    const pendingRes = await filtered(
        supabase.from('leave_requests_masked').select('id', { count: 'exact', head: true }).is('deleted_at', null), f,
    ).eq('status', 'pending')
    if (pendingRes.error) return { error: pendingRes.error, data: null }
    if (pendingRes.count === null) return { error: { message: 'leave_requests_masked pending count: no count' }, data: null }
    const P = pendingRes.count

    const out: LeaveDbRow[] = []
    // ② 区间落在待审那一段里的部分
    if (from < P) {
        const r = done(await ordered(leaveRows(supabase, f).eq('status', 'pending')).range(from, Math.min(to, P - 1)))
        if (r.error || !r.data) return r
        out.push(...r.data)
    }
    // ③ 区间落在其余那一段里的部分(下标从 P 起算)
    if (to >= P) {
        const r = done(await ordered(leaveRows(supabase, f).neq('status', 'pending')).range(Math.max(from - P, 0), to - P))
        if (r.error || !r.data) return r
        out.push(...r.data)
    }
    return { error: null, data: out }
}

export async function shapeLeaveRows(supabase: Client, raw: LeaveDbRow[]): Promise<LeaveRequestRow[]> {
    const locale = await getLocale()
    const [empRes, typeRes] = await Promise.all([
        supabase.from('employees_masked').select('id, code, legal_name').is('deleted_at', null),
        supabase.from('leave_types').select('code, name_en, name_zh'),
    ])
    const empById = new Map((mustRows(empRes, 'employees_masked') as { id: string; code: string; legal_name: string }[]).map((e) => [e.id, e]))
    const typeByCode = new Map(mustRows(typeRes, 'leave_types').map((x) => [x.code, x]))
    // 待审在最前 —— 这是一张待办清单,不是一份档案。
    // ★ TABLE-FEATURES-1 Q12:这一句从前在这里用 JS 重排(截断之后才排,漏掉 300 条之外的待审);
    //   现在顺序由 leavePage 在数据库里、在截断之前定好,这里【不再重排】—— 否则读者点的列排序也会被洗掉。
    return raw.map((r) => {
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
