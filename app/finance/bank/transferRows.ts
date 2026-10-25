import 'server-only'

// TABLE-EXPORT-2a(Tim 2026-10-22,TABLE-EXPORT-2 Q2):行内转账那张表的【一份】读取 —— 页面与导出路由共用。
// 页面只画最近 TRANSFERS_SHOWN 笔(从前是一句不说的 .limit(50));表上方的 RowCapNotice 说出「前 N 条,共 M 条」,
// 导出路由按同一条读取、同一个排序翻页取全(lib/export/serverRows.ts,上限 50,000)。
// ★ 排序在 transfer_date / created_at 之后补一个 id —— 翻页取全要一个【唯一】的次序(同一刻建的两笔不再随机互换)。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'
import { formatDate } from '@/lib/dates'
import { getLocale } from '@/lib/i18n/server'
import type { TransferRow } from './TransfersTable'
import { parseListSort, applyListSort, setSortParams, type ListSort } from '@/lib/listSort'

type Client = SupabaseClient<Database>

/** 页面画多少笔 —— 与转换之前同一个数。 */
export const TRANSFERS_SHOWN = 50

/**
 * ★ TABLE-FEATURES-1(Tim 2026-10-25 Q9):可排的列 —— 列键 → `bank_transfers` 上的列(lib/listSort.ts 的规矩)。
 *   只画前 TRANSFERS_SHOWN 笔,所以在数据库里排:那 50 笔是【按选中的次序】取的前 50 笔。
 *   两头账户是拼出来的文字;转出 / 转入金额各带各的账户币种,没有本位币那一列 —— 不可排;状态是另查的冲销申请 —— 不可排。
 * ★ 默认不变(Q7):转账日新的在前,平局按建立时刻、再按 id。
 */
export const TRANSFER_SORT = { date: 'transfer_date', ref: 'bank_reference' } as const
export type TransferSortKey = keyof typeof TRANSFER_SORT
const TRANSFER_SORT_DEFAULT: ListSort<TransferSortKey> = { key: 'date', dir: 'desc' }

export type TransferListParams = { sort: ListSort<TransferSortKey> }

export function parseTransferListParams(sp: { sort?: string; dir?: string }): TransferListParams {
    return { sort: parseListSort(sp, Object.keys(TRANSFER_SORT) as TransferSortKey[], TRANSFER_SORT_DEFAULT) }
}

/** 导出路由的地址:这张表没有筛选,只带排序。 */
export function transferExportHref(p: TransferListParams): string {
    return `/finance/bank/transfers/export?${setSortParams(new URLSearchParams(), p.sort).toString()}`
}

export type TransferDbRow = {
    id: string
    transfer_date: string
    from_account: string
    to_account: string
    amount_out: number
    amount_in: number
    bank_reference: string | null
    reversed_at: string | null
}

export function transferCount(supabase: Client) {
    return supabase.from('bank_transfers').select('id', { count: 'exact', head: true })
}

export function transferPage(supabase: Client, p: TransferListParams, from: number, to: number) {
    // TABLE-FEATURES-1 Q9:ORDER BY 在 .range 之前 —— 上限按选中的次序取
    return applyListSort(
        supabase
            .from('bank_transfers')
            .select('id, transfer_date, from_account, to_account, amount_out, amount_in, bank_reference, reversed_at'),
        p.sort, TRANSFER_SORT, [['transfer_date', 'desc'], ['created_at', 'desc'], ['id', 'asc']],
    )
        .range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as TransferDbRow[] | null }))
}

/** 库里的行 → 表的行:两头账户的币种(bank_reconciliation_status)与未了结的冲销申请,各读一次。 */
export async function shapeTransferRows(supabase: Client, transfers: TransferDbRow[]): Promise<TransferRow[]> {
    const locale = await getLocale()
    const [ccyRows, openReversals] = await Promise.all([
        supabase.from('bank_reconciliation_status').select('account_code, currency'),
        supabase.from('payment_requests').select('id, code, transfer_id')
            .eq('kind', 'bank_transfer_reversal').in('status', ['submitted', 'approved']),
    ])
    const ccyOf = new Map((mustRows(ccyRows, 'bank account currencies') as unknown as
        { account_code: string; currency: string | null }[]).map((r) => [r.account_code, r.currency ?? '']))
    const openByTransfer = new Map(mustRows(openReversals, 'open transfer reversal requests').map((r) => [r.transfer_id, r]))
    return transfers.map((x) => ({
        id: x.id,
        dateText: formatDate(x.transfer_date, locale),
        dateRaw: x.transfer_date,
        fromAccount: x.from_account,
        toAccount: x.to_account,
        fromCurrency: ccyOf.get(x.from_account) ?? '',
        toCurrency: ccyOf.get(x.to_account) ?? '',
        amountOut: x.amount_out,
        amountIn: x.amount_in,
        reference: x.bank_reference,
        reversed: x.reversed_at !== null,
        openRequestId: openByTransfer.get(x.id)?.id ?? null,
        openRequestCode: openByTransfer.get(x.id)?.code ?? null,
    }))
}
