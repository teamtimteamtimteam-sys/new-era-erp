// app/finance/expenses/page.tsx
// 开支列表:最新在前(expense_date DESC, created_at DESC),expense_date 日期区间 +
// 付款状态 + 费用科目筛选,count+range 分页(端口自收付款列表)。
// 表格上方汇总行 = 当前筛选集的笔数 + USD 合计(全筛选集,不只当前页)。
//
// CONV-4:套 CONV-1 的两文件模板。★ state 恒为 'ok',不用 'empty'★——
// 这一页的筛选工具栏是真实的【出口】(改筛选就能看到别的行),它必须与表格
// 一起【无条件】可见;若按当前筛选集的行数去驱动 ListPage 的 empty 分支,
// 会把工具栏也一起藏起来,正是 CONV-3 §⑧-2 记过的"空态吞掉出口"同一个缺陷,
// 只是换成了"筛选" 而不是"新增表单"。处置与 Kind-E 相同:【回答它的层】
// 挪到 DataTable 自己的 empty prop —— 而这本来就是这一页转换前的真实行为
// (工具栏此前从不在任何行数判断里面)。
import { Button } from '@/app/components/ui/button'
import { Suspense } from 'react'
import { getBaseCurrency } from '@/lib/currency'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatMoneyBare } from '@/lib/format'
import ExpensesToolbar from './ExpensesToolbar'
import ExpensesTable from './ExpensesTable'
import { setSortParams } from '@/lib/listSort'
import {
    parseExpenseListParams, resolveExpenseFilter, applyExpenseFilters, expenseCount, expensePage,
    expenseAccountOptions, shapeExpenseRows, expenseExportHref,
} from './expenseRows'
import { mustRows, mustCount } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'

const PAGE_SIZE = 20

function parsePage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

export default async function ExpensesListPage({
    searchParams,
}: {
    searchParams: Promise<{ date_from?: string; date_to?: string; status?: string; account?: string; page?: string; sort?: string; dir?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    const t = await getTranslations()
    const locale = await getLocale()

    // TABLE-EXPORT-2a:读取、筛选与「库里的行 → 表的行」搬进 expenseRows.ts,与导出路由共用一份。
    const params = parseExpenseListParams(sp)
    const listParams = params
    const { dateFrom, dateTo, status, account } = params
    const requestedPage = parsePage(sp.page)

    // ★ EXPENSE-MULTILINE-1(Tim 2026-10-20,Q9):科目住在【行】上。按科目筛 = 【任何一行】记在这个科目上的单据;
    //   筛着科目时,合计只加【那几行】(一张三行单里只有一行是差旅,差旅的合计不该把另外两行也算进去)。
    //   不筛科目时合计照旧是表头合计之和。每一张单仍然是清单上的一行。
    const filter = await resolveExpenseFilter(supabase, params)
    const { accountLineBase } = filter

    // 1) 匹配总数 + 筛选集本位币合计(全集,不只当前页;页级规模小,直接取列求和)
    const [total, sumRes] = await Promise.all([
        expenseCount(supabase, filter).then((r) => mustCount(r, 'expenses count')),
        applyExpenseFilters(supabase.from('expenses').select('id, amount_base'), filter),
    ])

    const totalUsd =
        Math.round(
            (mustRows(sumRes, 'expenses (filtered total)') as { id: string; amount_base: number }[]).reduce(
                (s, r) => s + (account ? (accountLineBase.get(r.id) ?? 0) : r.amount_base),
                0
            ) * 100
        ) / 100
    const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * PAGE_SIZE
    const to = from + PAGE_SIZE - 1

    // 2) 取当前页(最新在前)
    const { data: expenses, error } = await expensePage(supabase, filter, from, to)

    if (error) {
        return (
            <div className="p-8">
                <h1 className="mb-4">{t('expense.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <details className="mt-2">
                        <summary className="cursor-pointer text-xs">{t('common.actionMessage.technicalDetail')}</summary>
                        <pre className="mt-1 text-xs">{JSON.stringify(error, null, 2)}</pre>
                    </details>
                </div>
            </div>
        )
    }

    // 3) 科目名(工具栏 + 行内展示)、这一页每张单的行科目、供应商名 —— 映射在 expenseRows.ts 里,与导出同一份
    const [accountOptions, tableRows] = await Promise.all([
        expenseAccountOptions(supabase, locale),
        shapeExpenseRows(supabase, expenses ?? []),
    ])

    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (dateFrom) params.set('date_from', dateFrom)
        if (dateTo) params.set('date_to', dateTo)
        if (status) params.set('status', status)
        if (account) params.set('account', account)
        setSortParams(params, listParams.sort)  // TABLE-FEATURES-1 Q9:翻页保留排序
        params.set('page', String(targetPage))
        return `/finance/expenses?${params.toString()}`
    }

    return (
        <ListPage
            title={t('expense.listTitle')}
            actions={
                <Button asChild>
                    <Link href="/finance/expenses/new">{t('expense.new')}</Link>
                </Button>
            }
            state={{ kind: 'ok' }}
        >
            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <ExpensesToolbar accounts={accountOptions} />
            </Suspense>

            {/* 汇总:当前筛选集的笔数 + USD 合计 */}
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-4">
                {account
                    ? t('expense.filteredTotalAccount', { count: total, amount: formatMoneyBare(totalUsd, '同句 filteredTotalAccount 文案里的 {ccy}'), ccy: baseCurrency, account })
                    : t('expense.filteredTotal', { count: total, amount: formatMoneyBare(totalUsd, '同句 filteredTotal 文案「{count} 笔 · {amount} {ccy}」里的 {ccy}'), ccy: baseCurrency })}
            </p>

            <ExpensesTable rows={tableRows} empty={t('expense.empty')} exportHref={expenseExportHref(params)}
                           sort={params.sort} shown={tableRows.length} total={total} />

            {/* 分页控件:服务端 <Link>;首页禁用上一页、末页禁用下一页 */}
            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Button asChild variant="outline">
                        <Link
                            href={pageHref(page - 1)}
                        >
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
                        <Link
                            href={pageHref(page + 1)}
                        >
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
