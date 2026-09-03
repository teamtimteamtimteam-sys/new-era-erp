// app/hr/employees/page.tsx
// 员工列表(读 employee_directory)。20/页 count+range 分页,部门/状态/办公室车间
// 筛选 + 姓名/编号搜索。
//
// 【列表上不出现任何薪酬列】—— employee_directory 里有 current_gross_pay,但列表
// 是最容易被旁人瞥见的地方;薪酬属受限内容,要看去个人档案页。
//
// CONV-5:套 CONV-1 的两文件模板。Q7:服务端 .order('code') + .range() 分页
// 一个字没变(DataTable 不接管排序)。
// ★ state 恒为 'ok' —— 筛选工具栏是真实出口,见 docs/list-page-template.md §⑩-3。
import { Suspense } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import EmployeesToolbar, { type DeptOption } from './EmployeesToolbar'
import EmployeesTable, { type EmployeeRow } from './EmployeesTable'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'

const PAGE_SIZE = 20

type Row = {
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

function parsePage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

export default async function EmployeesPage({
    searchParams,
}: {
    searchParams: Promise<{ q?: string; department?: string; status?: string; category?: string; page?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    const q = (sp.q ?? '').trim()
    const dept = (sp.department ?? '').trim()
    const status = (sp.status ?? '').trim()
    const category = (sp.category ?? '').trim()
    const requestedPage = parsePage(sp.page)

    interface Chain {
        eq(c: string, v: string): Chain
        or(f: string): Chain
    }
    const applyFilters = <T,>(query: T): T => {
        let chain = query as unknown as Chain
        if (dept) chain = chain.eq('department_id', dept)
        if (status) chain = chain.eq('employment_status', status)
        if (category) chain = chain.eq('work_category', category)
        if (q) {
            // or() 表达式里的逗号/括号会破坏语法,先清掉
            const safe = q.replace(/[,()]/g, ' ')
            chain = chain.or(`legal_name.ilike.%${safe}%,code.ilike.%${safe}%`)
        }
        return chain as unknown as T
    }

    const { count } = await applyFilters(
        supabase.from('employee_directory').select('employee_id', { count: 'exact', head: true })
    )
    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)

    const [rowsRes, deptRes] = await Promise.all([
        applyFilters(
            supabase
                .from('employee_directory')
                .select('employee_id, code, legal_name, preferred_name, department_name_en, department_name_zh, job_title, employment_type, work_category, employment_status, hire_date, work_pass_alert, days_to_work_pass_expiry')
        )
            .order('code')
            .range((page - 1) * PAGE_SIZE, (page - 1) * PAGE_SIZE + PAGE_SIZE - 1),
        supabase
            .from('departments')
            .select('id, code, name_en, name_zh')
            .is('deleted_at', null)
            .order('code'),
    ])

    const rows = (rowsRes.data as unknown as Row[] | null) ?? []
    const departments: DeptOption[] = (mustRows(deptRes)).map((d) => ({
        id: d.id,
        label: `${d.code} — ${locale === 'zh' ? d.name_zh : d.name_en}`,
    }))

    function pageHref(target: number) {
        const params = new URLSearchParams()
        if (q) params.set('q', q)
        if (dept) params.set('department', dept)
        if (status) params.set('status', status)
        if (category) params.set('category', category)
        params.set('page', String(target))
        return `/hr/employees?${params.toString()}`
    }

    const tableRows: EmployeeRow[] = rows.map((r) => ({
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
        hireDate: r.hire_date,
        workPassAlert: r.work_pass_alert,
        daysToWorkPassExpiry: r.days_to_work_pass_expiry,
    }))

    return (
        <ListPage
            title={t('hr.employeesTitle')}
            actions={
                <Link href="/hr/employees/new" className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700">
                    {t('hr.newEmployee')}
                </Link>
            }
            state={{ kind: 'ok' }}
        >
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <EmployeesToolbar departments={departments} />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">{t('finance.recordCount', { count: total })}</p>

            <EmployeesTable rows={tableRows} empty={t('hr.employeesEmpty')} />

            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Link href={pageHref(page - 1)} className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50">
                        {t('finance.pagination.prev')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('finance.pagination.prev')}
                    </span>
                )}
                <span className="text-sm text-gray-600">
                    {t('finance.pagination.pageOf', { current: page, total: totalPages })}
                </span>
                {page < totalPages ? (
                    <Link href={pageHref(page + 1)} className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50">
                        {t('finance.pagination.next')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('finance.pagination.next')}
                    </span>
                )}
            </div>
        </ListPage>
    )
}
