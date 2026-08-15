// CN-1:发票上的【贷项凭证】区 —— 已开的凭证,以及开一张新的。服务端组件。
//
// 【两个上限,逐行,在动手之前就在屏幕上】(CMP-2 的规矩)一条发票行同时被
// 两个不同的天花板管着,而它们对应两种完全不同的事:
//   未释放的负债  货【没有】发出去,这部分从来没变成收入 —— 冲它借 2500
//   已释放的收入  货交付了、收入认了,事后减价 —— 冲它借 4000
// 把两个数印在行上,人才知道自己在冲哪一种、最多能冲多少;等服务端拒绝之后
// 再告诉他,是把一次可以提前给出的答复推到最后。
//
// 【真正的把关仍在数据库】三条天花板在 create_credit_note 里、由触发器兜底,
// 屏幕上这两个数只是【上一次渲染时】的快照。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { formatAmount } from '@/lib/format'
import CreateCreditNoteControl, { type CnLineOption } from './CreateCreditNoteControl'

export default async function CreditNoteSection({
    invoiceId, invoiceCode, currency, isOrderKind, isVoid, openCcy,
    lines,
}: {
    invoiceId: string
    invoiceCode: string
    currency: string
    isOrderKind: boolean
    isVoid: boolean
    openCcy: number
    lines: { id: string; line_no: number; description: string; unit: string
             quantity: number; unit_price: number; amount_ccy: number }[]
}) {
    const t = await getTranslations()
    const locale = await getLocale()
    const dl = locale === 'zh' ? 'zh-CN' : 'en-US'
    const supabase = await createClient()

    // 【sale 型不列这一区,而且要说出为什么】它什么都不过账,应收长在
    // 不可变的 sales_records 上 —— 贷项凭证对它无从下手。它今天的更正路
    // 仍然是作废发票 / 冲销收款,那两条没有被这一刀改动。
    if (!isOrderKind) {
        return (
            <section className="mt-8">
                <h2 className="font-medium mb-1">{t('cn.title')}</h2>
                <p className="text-sm text-gray-600 bg-gray-50 border border-gray-200 rounded px-3 py-2">
                    {t('cn.saleKindNote')}
                </p>
            </section>
        )
    }

    const notes = mustRows(
        await supabase.from('credit_notes')
            .select('id, code, note_date, reason, currency, fx_rate, created_at')
            .eq('invoice_id', invoiceId).order('note_date', { ascending: false }),
        'credit_notes') as unknown as {
            id: string; code: string; note_date: string; reason: string
            currency: string; fx_rate: number; created_at: string }[]

    const noteIds = notes.map((n) => n.id)
    const noteLines = noteIds.length === 0 ? [] : (mustRows(
        await supabase.from('credit_note_lines')
            .select('credit_note_id, invoice_line_id, kind, qty, amount')
            .in('credit_note_id', noteIds),
        'credit_note_lines') as unknown as {
            credit_note_id: string; invoice_line_id: string; kind: string
            qty: number | null; amount: number }[])

    // 已发多少 —— 走订单行,与服务端天花板逐字同一条路(shipment_lines 是
    // "货真的离开了"的记录)。读不到销售模块的人看不到这个数,那时【不猜】。
    const canSeeSales = await can('module.sales.view')
    const invLineIds = lines.map((l) => l.id)
    const shipped = new Map<string, number>()
    if (canSeeSales && invLineIds.length > 0) {
        const il = mustRows(
            await supabase.from('invoice_lines_masked')
                .select('id, sales_order_line_id').in('id', invLineIds),
            'invoice_lines') as unknown as { id: string; sales_order_line_id: string | null }[]
        const solIds = il.map((r) => r.sales_order_line_id).filter(Boolean) as string[]
        if (solIds.length > 0) {
            const sl = mustRows(
                await supabase.from('shipment_lines')
                    .select('sales_order_line_id, qty').in('sales_order_line_id', solIds),
                'shipment_lines') as unknown as { sales_order_line_id: string; qty: number }[]
            const byOrderLine = new Map<string, number>()
            for (const r of sl)
                byOrderLine.set(r.sales_order_line_id, (byOrderLine.get(r.sales_order_line_id) ?? 0) + Number(r.qty))
            for (const r of il)
                if (r.sales_order_line_id)
                    shipped.set(r.id, byOrderLine.get(r.sales_order_line_id) ?? 0)
        }
    }

    // 历史贷记额,按【行 × 类型】—— 与服务端天花板同一个分组
    const priorBy = new Map<string, number>()
    for (const cl of noteLines)
        priorBy.set(cl.invoice_line_id + '|' + cl.kind,
            (priorBy.get(cl.invoice_line_id + '|' + cl.kind) ?? 0) + Number(cl.amount))

    const options: CnLineOption[] = lines.map((l) => {
        const shipQty = shipped.get(l.id)
        const released = shipQty === undefined ? null : Math.round(shipQty * Number(l.unit_price) * 100) / 100
        const priorA = priorBy.get(l.id + '|unshipped_cancel') ?? 0
        const priorB = priorBy.get(l.id + '|revenue_reduction') ?? 0
        return {
            id: l.id,
            line_no: l.line_no,
            description: l.description,
            unit: l.unit,
            amount_ccy: Number(l.amount_ccy),
            // 【读不到销售模块 → null,不是 0】0 会被读成"一件没发",而那是一句
            // 假话:真相是"你看不见"。控件据此把这一行标成受限而不是给一个假上限。
            unreleased: released === null ? null : Math.round((Number(l.amount_ccy) - released - priorA) * 100) / 100,
            releasedRemaining: released === null ? null : Math.round((released - priorB) * 100) / 100,
        }
    })

    const canEdit = await can('module.finance.edit')
    const fullySettled = openCcy <= 0

    return (
        <section className="mt-8">
            <h2 className="font-medium mb-1">{t('cn.title')}</h2>
            <p className="text-xs text-gray-500 mb-3">{t('cn.note')}</p>

            {notes.length > 0 && (
                <ul className="text-sm space-y-1 mb-3">
                    {notes.map((n) => {
                        const mine = noteLines.filter((l) => l.credit_note_id === n.id)
                        const total = mine.reduce((s, l) => s + Number(l.amount), 0)
                        return (
                            <li key={n.id} className="flex flex-wrap items-baseline gap-x-3">
                                <Link href={`/finance/credit-notes/${n.id}`}
                                      className="font-mono text-blue-600 hover:underline">{n.code}</Link>
                                <span className="text-gray-500">{new Date(n.note_date).toLocaleDateString(dl)}</span>
                                <span className="font-mono">−{formatAmount(total, n.currency)}</span>
                                <span className="text-gray-500">{n.reason}</span>
                            </li>
                        )
                    })}
                </ul>
            )}

            {/* 【禁用的理由长在控件旁边】—— 三种"开不了"指向三个不同的下一步 */}
            {isVoid ? (
                <p className="text-sm text-gray-600">{t('cn.blockedVoid')}</p>
            ) : !canEdit ? (
                <p className="text-sm text-gray-600">{t('common.restricted')} — {t('cn.needsFinanceEdit')}</p>
            ) : fullySettled ? (
                <p className="text-sm text-gray-600">{t('cn.blockedFullySettled')}</p>
            ) : !canSeeSales ? (
                // 【受限 ≠ 没有上限】看不到发货就算不出两个天花板,而给一个
                // 猜出来的上限比不给更坏 —— 服务端仍会按名拒,但人已经填完了。
                <p className="text-sm text-gray-600">{t('common.restricted')} — {t('cn.needsSalesView')}</p>
            ) : (
                <CreateCreditNoteControl
                    invoiceId={invoiceId}
                    invoiceCode={invoiceCode}
                    currency={currency}
                    openCcy={openCcy}
                    lines={options}
                />
            )}
        </section>
    )
}
