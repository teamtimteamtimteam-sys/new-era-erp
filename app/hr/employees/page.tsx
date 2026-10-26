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
import { Button } from '@/app/components/ui/button'
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
import { SavedViewsBar } from '@/app/components/ui/saved-views'
import { loadSavedViews } from '@/lib/savedViewsServer'
import {
    parseEmployeeListParams, employeeFilterQuery, employeeCount, employeePage, shapeEmployeeRows,
} from './employeeRows'

const PAGE_SIZE = 20

function parsePage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

export default async function EmployeesPage({
    searchParams,
}: {
    searchParams: Promise<{ q?: string; department?: string; status?: string; category?: string; page?: string; sort?: string; dir?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    // TABLE-FEATURES-3(Tim 2026-10-26 Q1–Q3):保存的视图 —— 地址为空时套用本人的默认视图(一次跳转,所以在任何别的查询之前)
    const savedViews = await loadSavedViews(supabase, { listKey: '/hr/employees', sp })
    const t = await getTranslations()
    const locale = await getLocale()

    // TABLE-EXPORT-1:筛选、读取与映射都搬进 employeeRows.ts —— 页面与导出路由共用【一份】。
    const params = parseEmployeeListParams(sp)
    const requestedPage = parsePage(sp.page)

    const { count } = await employeeCount(supabase, params)
    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)

    const [rowsRes, deptRes] = await Promise.all([
        employeePage(supabase, params, (page - 1) * PAGE_SIZE, (page - 1) * PAGE_SIZE + PAGE_SIZE - 1),
        supabase
            .from('departments')
            .select('id, code, name_en, name_zh')
            .is('deleted_at', null)
            .order('code'),
    ])

    const departments: DeptOption[] = (mustRows(deptRes)).map((d) => ({
        id: d.id,
        label: `${d.code} — ${locale === 'zh' ? d.name_zh : d.name_en}`,
    }))

    function pageHref(target: number) {
        const qs = employeeFilterQuery(params)
        qs.set('page', String(target))
        return `/hr/employees?${qs.toString()}`
    }

    // TABLE-EXPORT-1:读失败必须【失败】(mustRows)—— 此前这里是 `(rowsRes.data as …) ?? []`,一次权限错误会画成「没有员工」。
    const tableRows: EmployeeRow[] = await shapeEmployeeRows(mustRows(rowsRes, 'employees'))
    // TABLE-EXPORT-1 Q2:导出取【全部匹配行】—— 同一套筛选,不带 page。
    const exportQs = employeeFilterQuery(params).toString()
    const exportHref = exportQs ? `/hr/employees/export?${exportQs}` : '/hr/employees/export'

    return (
        <ListPage
            title={t('hr.employeesTitle')}
            actions={
                <Button asChild>
                    <Link href="/hr/employees/new">{t('hr.newEmployee')}</Link>
                </Button>
            }
            state={{ kind: 'ok' }}
        >
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <SavedViewsBar listKey="/hr/employees" views={savedViews} />
                <EmployeesToolbar departments={departments} />
            </Suspense>

            <p className="text-sm text-[color:var(--brand-muted-text)] mb-4">{t('finance.recordCount', { count: total })}</p>

            <EmployeesTable rows={tableRows} empty={t('hr.employeesEmpty')} exportHref={exportHref}
                            sort={params.sort} shown={tableRows.length} total={total} />

            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Button asChild variant="outline">
                        <Link href={pageHref(page - 1)}>
                            {t('finance.pagination.prev')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" disabled>
                        {t('finance.pagination.prev')}
                    </Button>
                )}
                <span className="text-sm text-[color:var(--brand-muted-text)]">
                    {t('finance.pagination.pageOf', { current: page, total: totalPages })}
                </span>
                {page < totalPages ? (
                    <Button asChild variant="outline">
                        <Link href={pageHref(page + 1)}>
                            {t('finance.pagination.next')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" disabled>
                        {t('finance.pagination.next')}
                    </Button>
                )}
            </div>
        </ListPage>
    )
}
