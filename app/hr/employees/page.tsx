// app/hr/employees/page.tsx
// 员工列表(读 employee_directory)。20/页 count+range 分页,部门/状态/办公室车间
// 筛选 + 姓名/编号搜索。
//
// 【列表上不出现任何薪酬列】—— employee_directory 里有 current_gross_pay,但列表
// 是最容易被旁人瞥见的地方;薪酬属受限内容,要看去个人档案页。
import { Suspense } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import EmployeesToolbar, { type DeptOption } from './EmployeesToolbar'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

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

    const statusPill = (s: string) => {
        const cls =
            s === 'active'
                ? 'bg-green-100 text-green-800'
                : s === 'probation'
                  ? 'bg-amber-100 text-amber-800'
                  : s === 'notice'
                    ? 'bg-orange-100 text-orange-800'
                    : 'bg-gray-200 text-gray-600'
        return <span className={'px-2 py-1 rounded text-xs ' + cls}>{t('hr.employmentStatus.' + s)}</span>
    }

    return (
        <div className="p-8">
            <div className="flex justify-between items-center mb-4">
                <h1 className="text-2xl font-bold">{t('hr.employeesTitle')}</h1>
                <Link
                    href="/hr/employees/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('hr.newEmployee')}
                </Link>
            </div>

            <Suspense fallback={<div className="mb-4 h-10" />}>
                <EmployeesToolbar departments={departments} />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">{t('finance.recordCount', { count: total })}</p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colCode')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colLegalName')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colDepartment')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colJobTitle')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colEmploymentType')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colWorkCategory')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colStatus')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colHireDate')}</th>
                    </tr>
                </thead>
                <tbody>
                    {rows.map((r) => (
                        <tr key={r.employee_id}>
                            <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                <Link
                                    href={`/hr/employees/${r.employee_id}`}
                                    className="text-blue-600 hover:underline"
                                >
                                    {r.code}
                                </Link>
                                {/* 准证到期提醒:名单上就能看见,不用逐个点开 */}
                                {r.work_pass_alert && (
                                    <span
                                        title={t('hr.alertType.work_pass_expiry')}
                                        className={
                                            'ml-2 px-1.5 py-0.5 rounded text-xs ' +
                                            (r.work_pass_alert === 'expired'
                                                ? 'bg-red-100 text-red-800'
                                                : r.work_pass_alert === 'critical'
                                                  ? 'bg-amber-100 text-amber-800'
                                                  : 'bg-gray-200 text-gray-600')
                                        }
                                    >
                                        ⚠ {r.days_to_work_pass_expiry}d
                                    </span>
                                )}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                {r.legal_name}
                                {r.preferred_name && (
                                    <span className="text-gray-500 text-sm ml-1">({r.preferred_name})</span>
                                )}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm">
                                {(locale === 'zh' ? r.department_name_zh : r.department_name_en) ?? '—'}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm">{r.job_title ?? '—'}</td>
                            <td className="border border-gray-300 px-4 py-2 text-sm">
                                {t('hr.employmentType.' + r.employment_type)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm">
                                {t('hr.workCategory.' + r.work_category)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{statusPill(r.employment_status)}</td>
                            <td className="border border-gray-300 px-4 py-2 text-sm">{r.hire_date}</td>
                        </tr>
                    ))}
                    {rows.length === 0 && (
                        <tr>
                            <td colSpan={8} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('hr.employeesEmpty')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>

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
        </div>
    )
}
