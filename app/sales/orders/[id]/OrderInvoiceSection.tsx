// SO-3a:订单的【开票】区 —— 逐行可开状态、既有发票、开票控件。服务端组件。
//
// 【为什么长在订单页上】选项 C 之下订单流【先开票后发货】:开票是订单流程的
// 下一步,做这一步的人正看着订单。发票本身仍是财务单据(module.finance.*),
// 所以这一区对无 finance.view 的读者显示「受限」—— 空白读起来是"没开过票",
// 而那与"你看不见发票"是两回事(lib/permissions.ts 的那一课)。
//
// 【按钮只给持 finance.edit 的人】create_order_invoice 要 module.finance.edit
// (与 create_invoice 同一个码 —— 同一种单据不该由两个码把门,理由在函数头)。
// 不持码的人看到的是一句说明,不是一个必然被拒的按钮。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import CreateOrderInvoiceControl from './CreateOrderInvoiceControl'

type InvoiceRow = {
    id: string
    code: string
    issue_date: string
    status: string
    void_reason: string | null
}

type BilledLine = { sales_order_line_id: string | null; invoice_id: string }

export default async function OrderInvoiceSection({
    orderId,
    status,
    lines,
}: {
    orderId: string
    status: string
    lines: { id: string; line_no: number; material_code: string; quantity: number; unit: string }[]
}) {
    const t = await getTranslations()
    const locale = await getLocale()
    const dl = locale === 'zh' ? 'zh-CN' : 'en-US'

    const canSeeFinance = await can('module.finance.view')
    const canBill = await can('module.finance.edit')

    if (!canSeeFinance) {
        return (
            <section className="mt-8">
                <h2 className="font-medium mb-1">{t('sales.invoice.title')}</h2>
                {/* 「受限」,不是空白 —— 空白读起来是"没开过票" */}
                <p className="text-sm text-gray-600">
                    {t('common.restricted')} — {t('sales.invoice.needsFinanceView')}
                </p>
            </section>
        )
    }

    const supabase = await createClient()
    const invoices = mustRows(
        await supabase
            .from('invoices_masked')
            .select('id, code, issue_date, status, void_reason')
            .eq('sales_order_id', orderId)
            .order('issue_date'),
        'invoices'
    ) as unknown as InvoiceRow[]

    // 每行是否已挂在【在册】发票上 —— 与 uq_invoice_lines_live_order_line 同口径
    const lineIds = lines.map((l) => l.id)
    const billed =
        lineIds.length === 0
            ? []
            : (mustRows(
                  await supabase
                      .from('invoice_lines_masked')
                      .select('sales_order_line_id, invoice_id')
                      .in('sales_order_line_id', lineIds)
                      .eq('invoice_voided', false),
                  'invoice_lines'
              ) as unknown as BilledLine[])
    const billedSet = new Set(billed.map((b) => b.sales_order_line_id))
    const unbilled = lines.filter((l) => !billedSet.has(l.id))
    const isConfirmed = status === 'confirmed'

    return (
        <section className="mt-8">
            <h2 className="font-medium mb-1">{t('sales.invoice.title')}</h2>
            <p className="text-xs text-gray-500 mb-3">{t('sales.invoice.note')}</p>

            {invoices.length > 0 && (
                <ul className="text-sm space-y-1 mb-3">
                    {invoices.map((i) => (
                        <li key={i.id} className="flex flex-wrap items-baseline gap-x-3">
                            <Link href={`/finance/invoices/${i.id}`} className="text-blue-600 hover:underline font-mono">
                                {i.code}
                            </Link>
                            <span className="text-gray-500">{new Date(i.issue_date).toLocaleDateString(dl)}</span>
                            {i.status === 'void' ? (
                                <span className="text-red-700 text-xs">
                                    {t('sales.invoice.voided')}{i.void_reason ? ` · ${i.void_reason}` : ''}
                                </span>
                            ) : (
                                <span className="text-green-800 text-xs">{t('sales.invoice.posted')}</span>
                            )}
                        </li>
                    ))}
                </ul>
            )}

            {/* 逐行可开状态 —— "开过没有"是看订单的人的问题 */}
            <ul className="text-sm space-y-0.5 mb-3">
                {lines.map((l) => (
                    <li key={l.id} className="text-gray-600">
                        #{l.line_no} <span className="font-mono">{l.material_code}</span> · {l.quantity} {l.unit} ·{' '}
                        {billedSet.has(l.id) ? (
                            <span className="text-green-800">{t('sales.invoice.lineBilled')}</span>
                        ) : (
                            <span>{t('sales.invoice.lineUnbilled')}</span>
                        )}
                    </li>
                ))}
            </ul>

            {/* 禁用的理由长在控件旁边 */}
            {!isConfirmed ? (
                <p className="text-sm text-gray-600 bg-gray-50 border border-gray-200 rounded px-3 py-2">
                    {t('sales.invoice.onlyConfirmed')}
                </p>
            ) : unbilled.length === 0 ? (
                <p className="text-sm text-gray-600">{t('sales.invoice.fullyBilled')}</p>
            ) : canBill ? (
                <CreateOrderInvoiceControl orderId={orderId} unbilledCount={unbilled.length} />
            ) : (
                <p className="text-sm text-gray-600">
                    {t('common.restricted')} — {t('sales.invoice.needsFinanceEdit')}
                </p>
            )}
        </section>
    )
}
