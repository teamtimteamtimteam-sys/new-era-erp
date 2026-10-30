import 'server-only'

// TABLE-EXPORT-2a(Tim 2026-10-22 Q2):贷项凭证列表的【一份】读取 —— 页面与导出路由共用。
// 页面取一页(.range),导出路由翻页取全(lib/export/serverRows.ts,上限 50,000);两者同一个 select、同一个映射。
// 排序 note_date DESC, code DESC 之后补 id —— 翻页取全要一个【唯一】的次序。
// ★ 客户那一格从前是一个在服务端画好的 ReactNode —— 它过得了 server→client 的边界,过不了 JSON(导出路由)。
//   现在交出去的是【纯数据】(受限与否 + 编号 + 名称),由表来画,也由表来导出(受限 → 「受限」,Tim TABLE-EXPORT-1 Q3)。
// 金额:凭证本身不存合计,它是各行之和(详情页也是这么算的 —— 一份实现两处读)。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { can } from '@/lib/permissions'
import { formatDate } from '@/lib/dates'
import { getLocale } from '@/lib/i18n/server'
import { inChunks } from '@/lib/export/serverRows'
import type { CreditNoteRow } from './CreditNotesTable'
import { parseListSort, applyListSort, setSortParams, type ListSort } from '@/lib/listSort'
import { mustRows } from '@/lib/db-helpers'
import { shapeListTotals, type ListTotal } from '@/lib/listTotals'
import { readAll, readAllIn } from '@/lib/readAll'

type Client = SupabaseClient<Database>

/**
 * ★ TABLE-FEATURES-1(Tim 2026-10-25 Q9):可排的列 —— 列键 → `credit_notes` 上的列(lib/listSort.ts 的规矩)。
 *   客户、对冲发票是查出来的,合计是各行之和,签发是另一张表的版本号 —— 都不可排。
 * ★ 默认不变(Q7):凭证日新的在前,平局按单号倒序、再按 id。
 */
export const CREDIT_NOTE_SORT = { code: 'code', noteDate: 'note_date', reason: 'reason' } as const
export type CreditNoteSortKey = keyof typeof CREDIT_NOTE_SORT
const CREDIT_NOTE_SORT_DEFAULT: ListSort<CreditNoteSortKey> = { key: 'noteDate', dir: 'desc' }

export type CreditNoteListParams = { sort: ListSort<CreditNoteSortKey> }

export function parseCreditNoteListParams(sp: { sort?: string; dir?: string }): CreditNoteListParams {
    return { sort: parseListSort(sp, Object.keys(CREDIT_NOTE_SORT) as CreditNoteSortKey[], CREDIT_NOTE_SORT_DEFAULT) }
}

/** 导出路由的地址:这一页没有筛选,只带排序。 */
export function creditNoteExportHref(p: CreditNoteListParams): string {
    return `/finance/credit-notes/export?${setSortParams(new URLSearchParams(), p.sort).toString()}`
}

export type CreditNoteDbRow = { id: string; code: string; note_date: string; currency: string; invoice_id: string; reason: string }

/**
 * TABLE-FEATURES-2(Tim 2026-10-25 Q1):表尾合计 —— 所有凭证的行之和,按凭证币种各一行,库算
 * (db/functions/list_totals_credit_notes.sql)。这一页没有筛选。
 */
export async function creditNoteTotals(supabase: Client): Promise<ListTotal[]> {
    const res = await readAll(() => supabase.rpc('list_totals_credit_notes'), { label: 'list_totals_credit_notes', key: ['grp', 'currency', 'measure', 'total', 'restricted'] })
    return shapeListTotals(mustRows(res, 'credit notes totals'))
}

export function creditNoteCount(supabase: Client) {
    return supabase.from('credit_notes').select('id', { count: 'exact', head: true })
}

export function creditNotePage(supabase: Client, p: CreditNoteListParams, from: number, to: number) {
    return applyListSort(
        supabase
            .from('credit_notes')
            .select('id, code, note_date, currency, invoice_id, reason'),
        p.sort, CREDIT_NOTE_SORT, [['note_date', 'desc'], ['code', 'desc'], ['id', 'asc']],
    )
        .range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as CreditNoteDbRow[] | null }))
}

export async function shapeCreditNoteRows(supabase: Client, notes: CreditNoteDbRow[]): Promise<CreditNoteRow[]> {
    const locale = await getLocale()
    // 客户名走 customers 表,而它在 module.customers.view 那道门后面。
    // 【先问权限,再决定这一列说什么】—— 不问的话,查不到就渲染成「—」,
    // 而那读起来是"这张凭证没有客户",不是"你看不到客户"(lib/permissions.ts 存在的全部理由)。
    const canReadCustomers = await can('module.customers.view')
    const noteIds = notes.map((n) => n.id)
    const [lines, issues, invoices] = await Promise.all([
        inChunks(noteIds, (ids) => readAllIn(ids, (__ids) => supabase.from('credit_note_lines').select('credit_note_id, amount').in('credit_note_id', __ids), { label: 'credit_note_lines' })
            .then(({ data, error }) => ({ error, data: data as unknown as { credit_note_id: string; amount: number }[] | null })), 'credit_note_lines'),
        // 签发:最高版本号即当前版本;一条都没有 = 还没签发过(具名状态,不是 0)
        inChunks(noteIds, (ids) => readAllIn(ids, (__ids) => supabase.from('cn_issues').select('credit_note_id, version').in('credit_note_id', __ids), { label: 'cn_issues' })
            .then(({ data, error }) => ({ error, data: data as unknown as { credit_note_id: string; version: number }[] | null })), 'cn_issues'),
        inChunks(notes.map((n) => n.invoice_id).filter(Boolean), (ids) => readAllIn(ids, (__ids) => supabase.from('invoices_masked').select('id, code, customer_id').in('id', __ids), { label: 'invoices_masked' })
            .then(({ data, error }) => ({ error, data: data as unknown as { id: string; code: string; customer_id: string }[] | null })), 'invoices_masked'),
    ])
    const totalByNote = new Map<string, number>()
    for (const l of lines) totalByNote.set(l.credit_note_id, (totalByNote.get(l.credit_note_id) ?? 0) + Number(l.amount))
    const versionByNote = new Map<string, number>()
    for (const i of issues) versionByNote.set(i.credit_note_id, Math.max(versionByNote.get(i.credit_note_id) ?? 0, i.version))
    const invoiceById = new Map(invoices.map((i) => [i.id, i]))
    const customers = canReadCustomers
        ? await inChunks(invoices.map((i) => i.customer_id).filter(Boolean), (ids) => readAllIn(ids, (__ids) => supabase.from('customers').select('id, code, legal_name').in('id', __ids), { label: 'customers' })
            .then(({ data, error }) => ({ error, data: data as unknown as { id: string; code: string; legal_name: string }[] | null })), 'customers')
        : []
    const customerById = new Map(customers.map((c) => [c.id, c]))
    return notes.map((n) => {
        const inv = invoiceById.get(n.invoice_id)
        const c = inv ? customerById.get(inv.customer_id) : undefined
        return {
            id: n.id,
            code: n.code,
            noteDate: formatDate(n.note_date, locale),
            noteDateRaw: n.note_date,
            customerRestricted: !canReadCustomers,
            customerCode: c?.code ?? null,
            customerName: c?.legal_name ?? null,
            invoiceId: inv?.id ?? null,
            invoiceCode: inv?.code ?? null,
            total: Math.round((totalByNote.get(n.id) ?? 0) * 100) / 100,
            currency: n.currency,
            version: versionByNote.get(n.id) ?? null,
            reason: n.reason,
        }
    })
}
