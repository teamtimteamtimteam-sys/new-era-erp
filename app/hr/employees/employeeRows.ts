import 'server-only'

// TABLE-EXPORT-1(Tim 2026-10-22 Q2):员工名录的【一份】读取 —— 页面与导出路由共用。
// 页面取一页(.range),导出路由翻页取全(lib/export/serverRows.ts);两者走同一个 select、同一套筛选、
// 同一个「库里的行 → 表的行」映射,于是导出不可能比屏幕多一列或多一种口径。
// 【列表上不出现任何薪酬列】—— 这里的 select 照旧不取 current_gross_pay,导出也就取不到它。
// 排序在 code 之后补一个 employee_id —— 翻页取全要求一个【唯一】的次序。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatDate } from '@/lib/dates'
import type { EmployeeRow } from './EmployeesTable'
import { parseListSort, applyListSort, setSortParams, type ListSort } from '@/lib/listSort'

type Client = SupabaseClient<Database>

/**
 * ★ TABLE-FEATURES-1(Tim 2026-10-25 Q9):可排的列 —— 列键 → `employee_directory` 上的列(lib/listSort.ts 的规矩)。
 *   部门名在视图上按语言分两列,排哪一列跟着读者的语言走(employeePage 里换)。
 *   雇佣类型 / 工种 / 状态按库里的代码排(屏幕上是译名)。默认与今天一样:按工号,平局按 employee_id。
 */
export const EMPLOYEE_SORT = {
    code: 'code', legalName: 'legal_name', department: 'department_name_en', jobTitle: 'job_title',
    employmentType: 'employment_type', workCategory: 'work_category', status: 'employment_status', hireDate: 'hire_date',
} as const
export type EmployeeSortKey = keyof typeof EMPLOYEE_SORT
const EMPLOYEE_SORT_DEFAULT: ListSort<EmployeeSortKey> = { key: 'code', dir: 'asc' }

export type EmployeeListParams = { q: string; dept: string; status: string; category: string; sort: ListSort<EmployeeSortKey> }

export function parseEmployeeListParams(sp: Record<string, string | undefined>): EmployeeListParams {
    return {
        q: (sp.q ?? '').trim(),
        dept: (sp.department ?? '').trim(),
        status: (sp.status ?? '').trim(),
        category: (sp.category ?? '').trim(),
        sort: parseListSort(sp, Object.keys(EMPLOYEE_SORT) as EmployeeSortKey[], EMPLOYEE_SORT_DEFAULT),
    }
}

/** 把筛选参数写回地址栏的形状(不带 page)—— 翻页链接与导出链接共用。 */
export function employeeFilterQuery(p: EmployeeListParams): URLSearchParams {
    const params = new URLSearchParams()
    if (p.q) params.set('q', p.q)
    if (p.dept) params.set('department', p.dept)
    if (p.status) params.set('status', p.status)
    if (p.category) params.set('category', p.category)
    // TABLE-FEATURES-1 Q9:翻页链接与导出链接带上同一个顺序
    setSortParams(params, p.sort)
    return params
}

interface Chain {
    eq(c: string, v: string): Chain
    or(f: string): Chain
}
function applyEmployeeFilters<T>(query: T, p: EmployeeListParams): T {
    let chain = query as unknown as Chain
    if (p.dept) chain = chain.eq('department_id', p.dept)
    if (p.status) chain = chain.eq('employment_status', p.status)
    if (p.category) chain = chain.eq('work_category', p.category)
    if (p.q) {
        // or() 表达式里的逗号/括号会破坏语法,先清掉
        const safe = p.q.replace(/[,()]/g, ' ')
        chain = chain.or(`legal_name.ilike.%${safe}%,code.ilike.%${safe}%`)
    }
    return chain as unknown as T
}

const EMPLOYEE_LIST_SELECT =
    'employee_id, code, legal_name, preferred_name, department_name_en, department_name_zh, job_title, employment_type, work_category, employment_status, hire_date, work_pass_alert, days_to_work_pass_expiry'

type EmployeeDbRow = {
    employee_id: string
    code: string
    legal_name: string
    preferred_name: string | null
    department_name_en: string | null
    department_name_zh: string | null
    job_title: string | null
    employment_type: string
    work_category: string
    employment_status: string
    hire_date: string
    work_pass_alert: string | null
    days_to_work_pass_expiry: number | null
}

export function employeeCount(supabase: Client, p: EmployeeListParams) {
    return applyEmployeeFilters(
        supabase.from('employee_directory').select('employee_id', { count: 'exact', head: true }),
        p,
    )
}

export async function employeePage(supabase: Client, p: EmployeeListParams, from: number, to: number) {
    // TABLE-FEATURES-1 Q9:部门按读者语言的那一列排(与屏幕上那一格同一个名字)
    const columns = (await getLocale()) === 'zh' ? { ...EMPLOYEE_SORT, department: 'department_name_zh' } : EMPLOYEE_SORT
    const res = await applyListSort(
        applyEmployeeFilters(supabase.from('employee_directory').select(EMPLOYEE_LIST_SELECT), p),
        p.sort, columns, [['code', 'asc'], ['employee_id', 'asc']],
    )
        .range(from, to)
    return { data: res.data as unknown as EmployeeDbRow[] | null, error: res.error }
}

export async function shapeEmployeeRows(rows: EmployeeDbRow[]): Promise<EmployeeRow[]> {
    const t = await getTranslations()
    const locale = await getLocale()
    return rows.map((r) => ({
        employeeId: r.employee_id,
        code: r.code,
        legalName: r.legal_name,
        preferredName: r.preferred_name,
        // 部门名的语言在服务端选好 —— locale 不过 RSC 边界(CONV-1 §① 通则)
        departmentLabel: (locale === 'zh' ? r.department_name_zh : r.department_name_en) ?? '—',
        jobTitle: r.job_title ?? '—',
        employmentTypeLabel: t('hr.employmentType.' + r.employment_type),
        workCategoryLabel: t('hr.workCategory.' + r.work_category),
        employmentStatus: r.employment_status,
        hireDate: formatDate(r.hire_date, locale),
        hireDateRaw: r.hire_date,
        workPassAlert: r.work_pass_alert,
        daysToWorkPassExpiry: r.days_to_work_pass_expiry,
    }))
}
