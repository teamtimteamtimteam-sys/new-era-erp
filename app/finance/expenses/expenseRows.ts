import 'server-only'

// TABLE-EXPORT-2a(Tim 2026-10-22 Q2):开支列表的【一份】读取 —— 页面与导出路由共用。
// 页面取一页(.range),导出路由翻页取全(lib/export/serverRows.ts,上限 50,000);两者走同一套筛选
// (日期区间 · 付款状态 · 科目)、同一个 select、同一个映射。排序在 expense_date / created_at DESC 之后补 id ——
// 翻页取全要一个【唯一】的次序。
// ★ EXPENSE-MULTILINE-1(Tim 2026-10-20,Q9):科目住在【行】上。按科目筛 = 【任何一行】记在这个科目上的单据
//   —— 先把那组单据 id 解出来(resolveExpenseFilter),页面与导出用同一组。
//   (那一次读 expense_lines 不翻页:它与页面原样一致,读多于 1,000 行时同样会被截 —— 那是 Tim 2026-10-22
//    TABLE-EXPORT-2 Q3 登记的「读全部停在 1,000 行」那一族,不在本刀修。)

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { parseDateRange } from '@/lib/dateFilter'
import { getBaseCurrency } from '@/lib/currency'
import { mustRows } from '@/lib/db-helpers'
import { formatDate } from '@/lib/dates'
import { getLocale, getTranslations } from '@/lib/i18n/server'
import { inChunks } from '@/lib/export/serverRows'
import type { ExpenseRow } from './ExpensesTable'
import { parseListSort, applyListSort, setSortParams, type ListSort } from '@/lib/listSort'

type Client = SupabaseClient<Database>

/**
 * ★ TABLE-FEATURES-1(Tim 2026-10-25 Q9):可排的列 —— 列键 → `expenses` 上的列(lib/listSort.ts 的规矩)。
 *   金额按【本位币】那一列排:各行币种不同,原币金额放在一起比没有意义。
 *   科目住在行上、对方名称是查出来的 —— 都不可排。
 * ★ 默认不变(Q7):开支日新的在前,平局按建立时刻、再按 id。
 */
export const EXPENSE_SORT = { code: 'code', date: 'expense_date', amount: 'amount_base', paymentStatus: 'payment_status', postedStatus: 'status' } as const
export type ExpenseSortKey = keyof typeof EXPENSE_SORT
const EXPENSE_SORT_DEFAULT: ListSort<ExpenseSortKey> = { key: 'date', dir: 'desc' }

export type ExpenseListParams = { dateFrom: string; dateTo: string; status: '' | 'paid' | 'unpaid'; account: string; sort: ListSort<ExpenseSortKey> }

export function parseExpenseListParams(sp: { date_from?: string; date_to?: string; status?: string; account?: string; sort?: string; dir?: string }): ExpenseListParams {
    const { dateFrom, dateTo } = parseDateRange(sp)
    return {
        dateFrom, dateTo,
        status: sp.status === 'paid' || sp.status === 'unpaid' ? sp.status : '',
        account: (sp.account ?? '').trim(),
        sort: parseListSort(sp, Object.keys(EXPENSE_SORT) as ExpenseSortKey[], EXPENSE_SORT_DEFAULT),
    }
}

/** 科目筛选解出来的那组单据。`accountIds` 为 null = 不筛科目。 */
export type ExpenseFilter = ExpenseListParams & {
    accountIds: string[] | null
    /** 筛着科目时:单据 id → 这个科目那几行的本位币净额之和(页面的合计只加这几行) */
    accountLineBase: Map<string, number>
}

export async function resolveExpenseFilter(supabase: Client, p: ExpenseListParams): Promise<ExpenseFilter> {
    const accountLineBase = new Map<string, number>()
    if (p.account) {
        const linesRes = await supabase.from('expense_lines').select('expense_id, amount_base').eq('account_code', p.account)
        for (const l of mustRows(linesRes, 'expense_lines (account filter)') as { expense_id: string; amount_base: number }[]) {
            accountLineBase.set(l.expense_id, (accountLineBase.get(l.expense_id) ?? 0) + Number(l.amount_base))
        }
    }
    // 一个没有任何一行落在这个科目上的筛选,应当是【空】,而不是"不筛";in.() 收一个永远对不上的 id。
    const NO_MATCH = '00000000-0000-0000-0000-000000000000'
    const accountIds = p.account ? (accountLineBase.size ? [...accountLineBase.keys()] : [NO_MATCH]) : null
    return { ...p, accountIds, accountLineBase }
}

// 过滤链(expenses 不可变表,无软删)。最小链式子集,避免 supabase 深泛型。
interface Chain {
    gte(c: string, v: string): Chain
    lte(c: string, v: string): Chain
    eq(c: string, v: string): Chain
    in(c: string, v: string[]): Chain
}
export function applyExpenseFilters<T>(query: T, f: ExpenseFilter): T {
    let chain = query as unknown as Chain
    if (f.dateFrom) chain = chain.gte('expense_date', f.dateFrom)
    if (f.dateTo) chain = chain.lte('expense_date', f.dateTo)
    if (f.status) chain = chain.eq('payment_status', f.status)
    if (f.accountIds) chain = chain.in('id', f.accountIds)
    return chain as unknown as T
}

export type ExpenseDbRow = {
    id: string; code: string; expense_date: string; amount_ccy: number; currency: string; amount_base: number
    payment_status: string; supplier_id: string | null; payee_name: string | null; status: string
}

export function expenseCount(supabase: Client, f: ExpenseFilter) {
    return applyExpenseFilters(supabase.from('expenses').select('id', { count: 'exact', head: true }), f)
}

export function expensePage(supabase: Client, f: ExpenseFilter, from: number, to: number) {
    return applyListSort(
        applyExpenseFilters(
            supabase
                .from('expenses')
                .select('id, code, expense_date, amount_ccy, currency, amount_base, payment_status, supplier_id, payee_name, status'),
            f,
        ),
        f.sort, EXPENSE_SORT, [['expense_date', 'desc'], ['created_at', 'desc'], ['id', 'asc']],
    )
        .range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as ExpenseDbRow[] | null }))
}

/** 导出路由的地址:同一套筛选,不带 page。 */
export function expenseExportHref(p: ExpenseListParams): string {
    const params = new URLSearchParams()
    if (p.dateFrom) params.set('date_from', p.dateFrom)
    if (p.dateTo) params.set('date_to', p.dateTo)
    if (p.status) params.set('status', p.status)
    if (p.account) params.set('account', p.account)
    setSortParams(params, p.sort)
    const qs = params.toString()
    return qs ? `/finance/expenses/export?${qs}` : '/finance/expenses/export'
}

/** 费用科目(工具栏选项 + 行内科目名)—— 页面与导出同一份。 */
export async function expenseAccountOptions(supabase: Client, locale: string) {
    const rows = mustRows(
        await supabase.from('accounts').select('code, name_en, name_zh').eq('account_type', 'expense').order('code'),
        'expense accounts',
    )
    return rows.map((a) => ({ code: a.code, name: locale === 'zh' ? a.name_zh : a.name_en }))
}

export async function shapeExpenseRows(supabase: Client, rows: ExpenseDbRow[]): Promise<ExpenseRow[]> {
    const [locale, t, baseCurrency] = await Promise.all([getLocale(), getTranslations(), getBaseCurrency()])
    const supplierIds = rows.map((r) => r.supplier_id).filter((x): x is string => !!x)
    const [accountOptions, suppliers, lines] = await Promise.all([
        expenseAccountOptions(supabase, locale),
        // LOG-1b:【这一处绝不过滤 counterparty_type】—— 解析器,不是选择器。过滤它只会让已有单据的对方名字变成空白。
        inChunks(supplierIds, (ids) => supabase.from('supplier_lookup').select('id, legal_name').in('id', ids)
            .then(({ data, error }) => ({ error, data: data as unknown as { id: string; legal_name: string }[] | null })), 'supplier_lookup'),
        inChunks(rows.map((r) => r.id), (ids) => supabase.from('expense_lines').select('expense_id, account_code').in('expense_id', ids)
            .then(({ data, error }) => ({ error, data: data as unknown as { expense_id: string; account_code: string }[] | null })), 'expense_lines (accounts)'),
    ])
    const accountsByExpense = new Map<string, Set<string>>()
    for (const l of lines) {
        const set = accountsByExpense.get(l.expense_id) ?? new Set<string>()
        set.add(l.account_code)
        accountsByExpense.set(l.expense_id, set)
    }
    const accountNameByCode = new Map(accountOptions.map((a) => [a.code, a.name]))
    const supplierNameById = new Map(suppliers.map((s) => [s.id, s.legal_name]))
    return rows.map((r) => {
        // 一个科目就印它;几个科目就说几个(Q9)
        const codes = [...(accountsByExpense.get(r.id) ?? new Set<string>())]
        const one = codes.length === 1 ? codes[0] : null
        return {
            id: r.id,
            code: r.code,
            expenseDate: formatDate(r.expense_date, locale),
            expenseDateRaw: r.expense_date,
            accountCode: one ?? '',
            accountName: one ? (accountNameByCode.get(one) ?? '') : t('expense.accountsMany', { n: codes.length }),
            amountCcy: r.amount_ccy,
            currency: r.currency,
            amountBase: r.amount_base,
            baseCurrency,
            paymentStatus: r.payment_status,
            counterparty: r.payment_status === 'unpaid'
                ? supplierNameById.get(r.supplier_id ?? '') ?? '—'
                : r.payee_name || '—',
            status: r.status,
        }
    })
}
