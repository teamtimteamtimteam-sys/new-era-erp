// app/finance/expenses/page.tsx
// 开支列表:最新在前(expense_date DESC, created_at DESC),expense_date 日期区间 +
// 付款状态 + 费用科目筛选,count+range 分页(端口自收付款列表)。
// 表格上方汇总行 = 当前筛选集的笔数 + USD 合计(全筛选集,不只当前页)。
import { Suspense } from 'react'
import { getBaseCurrency } from '@/lib/currency'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { parseDateRange } from '@/lib/dateFilter'
import { formatMoneyBare } from '@/lib/format'
import ExpensesToolbar from './ExpensesToolbar'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

const PAGE_SIZE = 20

function parsePage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

export default async function ExpensesListPage({
    searchParams,
}: {
    searchParams: Promise<{ date_from?: string; date_to?: string; status?: string; account?: string; page?: string }>
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

    const { dateFrom, dateTo } = parseDateRange(sp)
    const status = sp.status === 'paid' || sp.status === 'unpaid' ? sp.status : ''
    const account = (sp.account ?? '').trim()
    const requestedPage = parsePage(sp.page)

    // 过滤链(expenses 不可变表,无软删)。最小链式子集,避免 supabase 深泛型。
    interface Chain {
        gte(c: string, v: string): Chain
        lte(c: string, v: string): Chain
        eq(c: string, v: string): Chain
    }
    const applyFilters = <T,>(query: T): T => {
        let chain = query as unknown as Chain
        if (dateFrom) chain = chain.gte('expense_date', dateFrom)
        if (dateTo) chain = chain.lte('expense_date', dateTo)
        if (status) chain = chain.eq('payment_status', status)
        if (account) chain = chain.eq('account_code', account)
        return chain as unknown as T
    }

    // 1) 匹配总数 + 筛选集 USD 合计(全集,不只当前页;页级规模小,直接取列求和)
    const [{ count }, sumRes] = await Promise.all([
        applyFilters(supabase.from('expenses').select('id', { count: 'exact', head: true })),
        applyFilters(supabase.from('expenses').select('amount_base')),
    ])

    const total = count ?? 0
    const totalUsd =
        Math.round(
            ((sumRes.data as { amount_base: number }[] | null) ?? []).reduce(
                (s, r) => s + r.amount_base,
                0
            ) * 100
        ) / 100
    const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * PAGE_SIZE
    const to = from + PAGE_SIZE - 1

    // 2) 取当前页(最新在前)
    const { data: expenses, error } = await applyFilters(
        supabase
            .from('expenses')
            .select('id, code, expense_date, account_code, amount_ccy, currency, amount_base, payment_status, supplier_id, payee_name, status')
    )
        .order('expense_date', { ascending: false })
        .order('created_at', { ascending: false })
        .range(from, to)

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('expense.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const rows = expenses ?? []

    // 3) 科目名(工具栏 + 行内展示)与供应商名(页级小 .in)
    const [accountsRes, suppliersRes] = await Promise.all([
        supabase
            .from('accounts')
            .select('code, name_en, name_zh')
            .eq('account_type', 'expense')
            .order('code'),
        (() => {
            const supplierIds = Array.from(
                new Set(rows.map((r) => r.supplier_id).filter(Boolean))
            ) as string[]
            return supplierIds.length
                ? // LOG-1b:【这一处绝不过滤 counterparty_type】—— 解析器,不是选择器。
                  //         过滤它只会让已有单据的对方名字变成空白。
                  supabase.from('suppliers').select('id, legal_name').in('id', supplierIds)
                : Promise.resolve({ data: [] as { id: string; legal_name: string }[], error: null })
        })(),
    ])
    const accountOptions = (mustRows(accountsRes)).map((a) => ({
        code: a.code,
        name: locale === 'zh' ? a.name_zh : a.name_en,
    }))
    const accountNameByCode = new Map(accountOptions.map((a) => [a.code, a.name]))
    const supplierNameById = new Map((mustRows(suppliersRes)).map((s) => [s.id, s.legal_name]))

    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (dateFrom) params.set('date_from', dateFrom)
        if (dateTo) params.set('date_to', dateTo)
        if (status) params.set('status', status)
        if (account) params.set('account', account)
        params.set('page', String(targetPage))
        return `/finance/expenses?${params.toString()}`
    }

    return (
        <div className="p-8">
            <div className="flex justify-between items-center mb-4">
                <h1 className="text-2xl font-bold">{t('expense.listTitle')}</h1>
                <Link
                    href="/finance/expenses/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('expense.new')}
                </Link>
            </div>

            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <ExpensesToolbar accounts={accountOptions} />
            </Suspense>

            {/* 汇总:当前筛选集的笔数 + USD 合计 */}
            <p className="text-sm text-gray-600 mb-4">
                {t('expense.filteredTotal', { count: total, amount: formatMoneyBare(totalUsd, '同句 filteredTotal 文案「{count} 笔 · {amount} {ccy}」里的 {ccy}'), ccy: baseCurrency })}
            </p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('expense.colCode')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('expense.colDate')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('expense.colAccount')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('expense.colAmount')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('expense.colStatus')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('expense.colCounterparty')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colStatus')}</th>
                    </tr>
                </thead>
                <tbody>
                    {rows.map((r) => (
                        <tr key={r.id}>
                            <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                <Link
                                    href={`/finance/expenses/${r.id}`}
                                    className="text-blue-600 hover:underline"
                                >
                                    {r.code}
                                </Link>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{r.expense_date}</td>
                            <td className="border border-gray-300 px-4 py-2 text-sm">
                                <span className="font-mono">{r.account_code}</span>{' '}
                                {accountNameByCode.get(r.account_code) ?? ''}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {r.currency} {formatMoneyBare(r.amount_ccy, '同格内紧邻的 r.currency 前缀')}
                                {r.currency !== baseCurrency && (
                                    <span className="text-gray-500 ml-2">
                                        = {formatMoneyBare(r.amount_base, '同格内紧随其后的 {baseCurrency} 后缀')} {baseCurrency}
                                    </span>
                                )}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span
                                    className={
                                        'px-2 py-1 rounded text-xs ' +
                                        (r.payment_status === 'paid'
                                            ? 'bg-green-100 text-green-800'
                                            : 'bg-amber-100 text-amber-800')
                                    }
                                >
                                    {t('expense.status.' + r.payment_status)}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm">
                                {r.payment_status === 'unpaid'
                                    ? supplierNameById.get(r.supplier_id ?? '') ?? '—'
                                    : r.payee_name || '—'}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span
                                    className={
                                        'px-2 py-1 rounded text-xs ' +
                                        (r.status === 'posted'
                                            ? 'bg-green-100 text-green-800'
                                            : 'bg-gray-200 text-gray-700')
                                    }
                                >
                                    {t('finance.status.' + r.status)}
                                </span>
                            </td>
                        </tr>
                    ))}
                    {rows.length === 0 && (
                        <tr>
                            <td colSpan={7} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('expense.empty')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>

            {/* 分页控件:服务端 <Link>;首页禁用上一页、末页禁用下一页 */}
            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Link
                        href={pageHref(page - 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
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
                    <Link
                        href={pageHref(page + 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
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
