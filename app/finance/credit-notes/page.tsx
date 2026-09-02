// app/finance/credit-notes/page.tsx
// FIX-1:贷项凭证【列表】。此前只有详情页存在,进去的唯一路是先打开那张发票 ——
// 也就是说「本月开过哪些贷项凭证」这个问题,得先知道答案才能问出口。
//
// 【为什么"状态"这一列写的是签发,不是单据状态】credit_notes 没有 status 列,
// 也没有作废:凭证只增不改(CREDIT_NOTE_IMMUTABLE,见详情页抬头)。它唯一
// 真实存在的状态是【有没有签发过给客户的那份 PDF】,以及签到第几版。
// 编一个「已过账 / 草稿」出来会比留白更坏(FIN-26 那条:伪造的出处不如空着)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { formatAmount } from '@/lib/format'
import { can } from '@/lib/permissions'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

const PAGE_SIZE = 20

function parsePage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

export default async function CreditNotesPage({
    searchParams,
}: {
    searchParams: Promise<{ page?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const sp = await searchParams
    const t = await getTranslations()
    const supabase = await createClient()

    // 客户名走 customers 表,而它在 module.customers.view 那道门后面。
    // 【先问权限,再决定这一列说什么】—— 不问的话,查不到就渲染成「—」,
    // 而那读起来是"这张凭证没有客户",不是"你看不到客户"(lib/permissions.ts
    // 存在的全部理由)。同一句话在发票详情页 actorLabel 里已经写过一次。
    const canReadCustomers = await can('module.customers.view')

    const { count } = await supabase
        .from('credit_notes')
        .select('id', { count: 'exact', head: true })
    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))
    const page = Math.min(parsePage(sp.page), totalPages)

    const notes = mustRows(
        await supabase
            .from('credit_notes')
            .select('id, code, note_date, currency, invoice_id, reason')
            .order('note_date', { ascending: false })
            .order('code', { ascending: false })
            .range((page - 1) * PAGE_SIZE, (page - 1) * PAGE_SIZE + PAGE_SIZE - 1),
        'credit_notes'
    ) as {
        id: string; code: string; note_date: string
        currency: string; invoice_id: string; reason: string
    }[]

    const noteIds = notes.map((n) => n.id)
    const invoiceIds = Array.from(new Set(notes.map((n) => n.invoice_id).filter(Boolean)))

    // 金额:凭证本身不存合计,它是各行之和(详情页也是这么算的 —— 一份实现两处读)
    const lines = noteIds.length
        ? (mustRows(
              await supabase
                  .from('credit_note_lines')
                  .select('credit_note_id, amount')
                  .in('credit_note_id', noteIds),
              'credit_note_lines'
          ) as { credit_note_id: string; amount: number }[])
        : []
    const totalByNote = new Map<string, number>()
    for (const l of lines) {
        totalByNote.set(l.credit_note_id, (totalByNote.get(l.credit_note_id) ?? 0) + Number(l.amount))
    }

    // 签发:最高版本号即当前版本;一条都没有 = 还没签发过(具名状态,不是 0)
    const issues = noteIds.length
        ? (mustRows(
              await supabase
                  .from('cn_issues')
                  .select('credit_note_id, version')
                  .in('credit_note_id', noteIds),
              'cn_issues'
          ) as { credit_note_id: string; version: number }[])
        : []
    const versionByNote = new Map<string, number>()
    for (const i of issues) {
        versionByNote.set(i.credit_note_id, Math.max(versionByNote.get(i.credit_note_id) ?? 0, i.version))
    }

    const invoices = invoiceIds.length
        ? (mustRows(
              await supabase.from('invoices_masked').select('id, code, customer_id').in('id', invoiceIds),
              'invoices_masked'
          ) as { id: string; code: string; customer_id: string }[])
        : []
    const invoiceById = new Map(invoices.map((i) => [i.id, i]))

    const customerIds = Array.from(new Set(invoices.map((i) => i.customer_id).filter(Boolean)))
    const customers =
        canReadCustomers && customerIds.length
            ? (mustRows(
                  await supabase.from('customers').select('id, code, legal_name').in('id', customerIds),
                  'customers'
              ) as { id: string; code: string; legal_name: string }[])
            : []
    const customerById = new Map(customers.map((c) => [c.id, c]))

    function customerCell(invoiceId: string) {
        if (!canReadCustomers) return <span className="text-gray-500">{t('common.restricted')}</span>
        const inv = invoiceById.get(invoiceId)
        const c = inv ? customerById.get(inv.customer_id) : undefined
        if (!c) return <span className="text-gray-400">—</span>
        return (
            <>
                <span className="font-mono text-xs text-gray-500">{c.code}</span> {c.legal_name}
            </>
        )
    }

    function pageHref(targetPage: number) {
        return `/finance/credit-notes?page=${targetPage}`
    }

    return (
        <div className="p-8">
            <h1 className="text-2xl font-bold mb-4">{t('cn.title')}</h1>

            {/* 【没有"新建"按钮是对的】贷项凭证只能从它要冲的那张发票上开,
                因为每一行的可冲上限是按发票行算出来的。所以这里说出那条路,
                而不是摆一个注定要先问"冲哪张发票"的钮。 */}
            <p className="text-sm text-gray-600 mb-4">{t('cn.listNote')}</p>

            <p className="text-sm text-gray-600 mb-4">{t('finance.recordCount', { count: total })}</p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('cn.colCode')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('cn.noteDate')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('cn.colCustomer')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('cn.againstInvoice')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('cn.totalLabel')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('cn.colIssued')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('cn.reason')}</th>
                    </tr>
                </thead>
                <tbody>
                    {notes.map((n) => {
                        const inv = invoiceById.get(n.invoice_id)
                        const version = versionByNote.get(n.id)
                        return (
                            <tr key={n.id}>
                                <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                    <Link
                                        href={`/finance/credit-notes/${n.id}`}
                                        className="text-blue-600 hover:underline"
                                    >
                                        {n.code}
                                    </Link>
                                </td>
                                <td className="border border-gray-300 px-4 py-2">{n.note_date}</td>
                                <td className="border border-gray-300 px-4 py-2">{customerCell(n.invoice_id)}</td>
                                <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                    {inv ? (
                                        <Link
                                            href={`/finance/invoices/${inv.id}`}
                                            className="text-blue-600 hover:underline"
                                        >
                                            {inv.code}
                                        </Link>
                                    ) : (
                                        <span className="text-gray-400">—</span>
                                    )}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                    {formatAmount(
                                        Math.round((totalByNote.get(n.id) ?? 0) * 100) / 100,
                                        n.currency
                                    )}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-sm">
                                    {version === undefined ? (
                                        <span className="text-gray-500">{t('cn.noIssues')}</span>
                                    ) : (
                                        <span className="px-2 py-1 rounded text-xs bg-green-100 text-green-800">
                                            {t('cn.issuedVersion', { n: version })}
                                        </span>
                                    )}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-sm text-gray-700">{n.reason}</td>
                            </tr>
                        )
                    })}
                    {notes.length === 0 && (
                        <tr>
                            <td colSpan={7} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('cn.empty')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>

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
