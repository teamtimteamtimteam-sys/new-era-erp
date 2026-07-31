// app/finance/invoices/[id]/page.tsx
// 发票详情:抬头卡【取自 bill_to_snapshot】(不是现在的客户资料 —— 几年后重打要看到
// 当时寄出的内容)+ 单据信息 + 明细行 + 小计/税/合计 + 收款情况(从明细行背后的
// sales_records 的核销行推导,与 AR 单据页同一套呈现:已冲销的收款灰色删除线)。
// 附件不挂这里 —— 凭据挂在 AR 单据(sales_record)本身。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatUsd, formatAmount } from '@/lib/format'
import { checkInvoicePdfCoverage } from '@/lib/invoiceFontCoverage'
import Subnav from '../../Subnav'
import VoidInvoiceControl from './VoidInvoiceControl'

type BillTo = {
    code?: string | null
    legal_name?: string | null
    short_name?: string | null
    country?: string | null
    tax_id?: string | null
    address?: string | null
    payment_terms?: string | null
    incoterm?: string | null
    contact_person?: string | null
    email?: string | null
    phone?: string | null
}

type AllocRow = {
    id: string
    allocated_usd: number
    sales_record_id: string | null
    payments: { id: string; code: string; payment_date: string; status: string } | null
}

export default async function InvoiceDetailPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const { data: inv, error } = await supabase
        .from('invoices')
        .select('id, code, customer_id, issue_date, due_date, payment_terms_days, currency, subtotal_usd, tax_rate_pct, tax_usd, total_usd, status, void_reason, voided_at, notes, terms_text, bill_to_snapshot')
        .eq('id', id)
        .single()

    if (error || !inv) {
        notFound()
    }

    // 公司抬头是否已填 —— 没填就不能出 PDF,页面上先给出提示。
    // 取整行(不只是 legal_name)是因为下面的字体覆盖检查要过一遍抬头/银行/页脚里
    // 所有会被印到 PDF 上的字段。
    const [{ data: company }, { data: financeSettings }] = await Promise.all([
        supabase.from('company_profile').select('*').limit(1).single(),
        supabase.from('finance_settings').select('gst_registration_no').limit(1).single(),
    ])
    const profileIncomplete = !company?.legal_name?.trim()

    const { data: lines } = await supabase
        .from('invoice_lines')
        .select('id, line_no, sales_record_id, description, quantity, unit, unit_price, amount_usd')
        .eq('invoice_id', id)
        .order('line_no', { ascending: true })

    const rows = lines ?? []
    const saleIds = rows.map((l) => l.sales_record_id)

    // 收款:这些销售上的全部核销行(含已冲销的,展示但不计入已收)
    const { data: allocs } = saleIds.length
        ? await supabase
              .from('payment_allocations')
              .select('id, allocated_usd, sales_record_id, payments(id, code, payment_date, status)')
              .in('sales_record_id', saleIds)
              .order('created_at', { ascending: true })
        : { data: [] as AllocRow[] }

    const allocRows = ((allocs as unknown as AllocRow[] | null) ?? [])
    const settled =
        Math.round(
            allocRows
                .filter((a) => a.payments?.status === 'posted')
                .reduce((s, a) => s + a.allocated_usd, 0) * 100
        ) / 100
    const open = Math.round((inv.total_usd - settled) * 100) / 100
    const paymentState = open <= 0 ? 'paid' : settled > 0 ? 'partial' : 'unpaid'

    const bill = (inv.bill_to_snapshot ?? {}) as BillTo
    const isVoid = inv.status === 'void'

    // 发票 PDF 内嵌的中文字体是【裁剪过的】(见 assets/fonts/subset.py),范围外的字
    // 会被静默画成空白。PDF 路由会拦下来返回 409,但那要等到有人去点"下载 PDF"才发现
    // —— 而那通常已经是准备把单据寄出去的时刻了。所以在详情页上【提前】暴露出来。
    const fontProblems =
        company && !profileIncomplete
            ? checkInvoicePdfCoverage({
                  invoice: {
                      code: inv.code,
                      issue_date: inv.issue_date,
                      due_date: inv.due_date,
                      payment_terms_days: inv.payment_terms_days,
                      currency: inv.currency,
                      subtotal_usd: Number(inv.subtotal_usd),
                      tax_rate_pct: Number(inv.tax_rate_pct),
                      tax_usd: Number(inv.tax_usd),
                      total_usd: Number(inv.total_usd),
                      notes: inv.notes,
                      terms_text: inv.terms_text,
                      bill_to: (inv.bill_to_snapshot ?? {}) as Record<string, string | null | undefined>,
                  },
                  lines: rows.map((l) => ({
                      line_no: l.line_no,
                      description: l.description,
                      quantity: Number(l.quantity),
                      unit: l.unit,
                      unit_price: Number(l.unit_price),
                      amount_usd: Number(l.amount_usd),
                  })),
                  company: company as Record<string, unknown> & { legal_name: string },
                  gstRegistrationNo: financeSettings?.gst_registration_no ?? null,
              })
            : []
    const pdfBlocked = profileIncomplete || fontProblems.length > 0

    return (
        <div className="p-8 max-w-5xl">
            <div className="mb-6">
                <Link href="/finance/invoices" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <div className="flex justify-between items-center mb-2">
                <h1 className="text-2xl font-bold">
                    {t('invoice.detailTitle')}
                    <span className="ml-3 font-mono text-base text-gray-500">{inv.code}</span>
                </h1>
                <div className="flex items-center gap-3">
                    {!pdfBlocked && (
                        <a
                            href={`/finance/invoices/${inv.id}/pdf`}
                            target="_blank"
                            rel="noopener noreferrer"
                            className="border border-gray-300 px-3 py-1 rounded hover:bg-gray-50 text-sm"
                        >
                            {t('invoice.downloadPdf')}
                        </a>
                    )}
                    {!isVoid && <VoidInvoiceControl invoiceId={inv.id} />}
                </div>
            </div>

            <Subnav />

            {profileIncomplete && (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-4 text-sm">
                    {t('invoice.profileIncomplete')}{' '}
                    <Link href="/finance/company" className="text-blue-600 hover:underline">
                        {t('company.title')}
                    </Link>
                </div>
            )}

            {fontProblems.length > 0 && (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-4 text-sm">
                    <p>{t('invoice.fontUnsupported')}</p>
                    <ul className="mt-2 space-y-0.5">
                        {fontProblems.map((p) => (
                            <li key={p.where}>
                                <span className="text-amber-800">{p.where}:</span>{' '}
                                <span className="font-medium text-base">{p.chars.join('  ')}</span>
                            </li>
                        ))}
                    </ul>
                </div>
            )}

            {isVoid && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4 text-sm">
                    {t('invoice.voidedBanner', {
                        date: inv.voided_at ? new Date(inv.voided_at).toLocaleString(dateLocale) : '—',
                        reason: inv.void_reason ?? '—',
                    })}
                </div>
            )}

            <div className="grid gap-4 md:grid-cols-2 mb-6">
                {/* 抬头:开票当刻的存档 */}
                <div className="border border-gray-300 rounded p-4">
                    <h2 className="font-bold mb-2">{t('invoice.billTo')}</h2>
                    <p className="text-sm font-medium">{bill.legal_name ?? '—'}</p>
                    {bill.code && <p className="text-xs text-gray-500 font-mono">{bill.code}</p>}
                    {bill.address && <p className="text-sm text-gray-600 whitespace-pre-line mt-1">{bill.address}</p>}
                    {bill.country && <p className="text-sm text-gray-600">{bill.country}</p>}
                    {bill.contact_person && <p className="text-sm text-gray-600 mt-1">{bill.contact_person}</p>}
                    {bill.email && <p className="text-sm text-gray-600 break-all">{bill.email}</p>}
                    {bill.phone && <p className="text-sm text-gray-600">{bill.phone}</p>}
                    {bill.tax_id && (
                        <p className="text-sm text-gray-600 mt-1">
                            {t('customers.form.taxId')}: {bill.tax_id}
                        </p>
                    )}
                    <p className="text-xs text-gray-400 mt-2">{t('invoice.snapshotNote')}</p>
                </div>

                {/* 单据信息 */}
                <div className="border border-gray-300 rounded p-4 text-sm space-y-1">
                    <div className="flex justify-between">
                        <span className="text-gray-600">{t('invoice.colCode')}</span>
                        <span className="font-mono font-medium">{inv.code}</span>
                    </div>
                    <div className="flex justify-between">
                        <span className="text-gray-600">{t('invoice.colIssueDate')}</span>
                        <span>{inv.issue_date}</span>
                    </div>
                    <div className="flex justify-between">
                        <span className="text-gray-600">{t('invoice.colDueDate')}</span>
                        <span>{inv.due_date}</span>
                    </div>
                    <div className="flex justify-between">
                        <span className="text-gray-600">{t('invoice.form.termsDays')}</span>
                        <span>{inv.payment_terms_days}</span>
                    </div>
                    <div className="flex justify-between">
                        <span className="text-gray-600">{t('output.sale.currency')}</span>
                        <span>{inv.currency}</span>
                    </div>
                </div>
            </div>

            {/* 明细行 */}
            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('invoice.colLineNo')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('invoice.colDescription')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('invoice.colQuantity')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('invoice.colUnitPrice')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('invoice.colAmount')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left" />
                    </tr>
                </thead>
                <tbody>
                    {rows.map((l) => (
                        <tr key={l.id}>
                            <td className="border border-gray-300 px-3 py-2 text-sm text-gray-500">{l.line_no}</td>
                            <td className="border border-gray-300 px-3 py-2 text-sm">{l.description}</td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                {l.quantity} {l.unit}
                            </td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                {formatUsd(l.unit_price)}
                            </td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                {formatUsd(l.amount_usd)}
                            </td>
                            <td className="border border-gray-300 px-3 py-2 text-sm">
                                {/* 每行都能跳回它背后的 AR 单据(凭据附件挂在那里)*/}
                                <Link
                                    href={`/finance/receivables/${l.sales_record_id}`}
                                    className="text-blue-600 hover:underline"
                                >
                                    {t('finance.arDocTitle')}
                                </Link>
                            </td>
                        </tr>
                    ))}
                </tbody>
            </table>

            {/* 合计 */}
            <div className="mt-4 max-w-sm ml-auto text-sm space-y-1">
                <div className="flex justify-between">
                    <span className="text-gray-600">{t('invoice.subtotal')}</span>
                    <span className="font-mono">{formatAmount(inv.subtotal_usd, inv.currency)}</span>
                </div>
                {Number(inv.tax_usd) !== 0 && (
                    <div className="flex justify-between">
                        <span className="text-gray-600">{t('invoice.tax', { rate: inv.tax_rate_pct })}</span>
                        <span className="font-mono">{formatUsd(inv.tax_usd)}</span>
                    </div>
                )}
                <div className="flex justify-between border-t pt-1 font-bold">
                    <span>{t('invoice.total')}</span>
                    <span className="font-mono">{formatAmount(inv.total_usd, inv.currency)}</span>
                </div>
            </div>

            {/* 标签是界面文字,跟随界面语言;条款正文是【单据数据】,按存下来的原样显示
                (发票一律英文开具,不因界面切换而变) */}
            {inv.terms_text && (
                <div className="mt-4 text-sm">
                    <span className="text-gray-500 mr-1">{t('invoice.termsLabel')}:</span>
                    <span className="text-gray-700">{inv.terms_text}</span>
                </div>
            )}
            {inv.notes && (
                <p className="text-sm text-gray-600 mt-2">
                    <span className="text-gray-500 mr-1">{t('finance.memo')}:</span>
                    {inv.notes}
                </p>
            )}

            {/* 收款情况 */}
            <section className="mt-8 pt-8 border-t">
                <h2 className="text-xl font-bold mb-3">{t('invoice.settlementTitle')}</h2>

                <div className="bg-gray-50 rounded p-4 mb-4 flex flex-wrap gap-x-8 gap-y-2 text-sm items-center">
                    <div>
                        <span className="text-gray-600 mr-1">{t('invoice.colSettled')}:</span>
                        <span className="font-mono">{formatUsd(settled)}</span>
                    </div>
                    <div>
                        <span className="text-gray-600 mr-1">{t('invoice.colOpen')}:</span>
                        <span className="font-mono font-bold">{formatUsd(open)}</span>
                    </div>
                    <span
                        className={
                            'px-2 py-1 rounded text-xs ' +
                            (paymentState === 'paid'
                                ? 'bg-green-100 text-green-800'
                                : paymentState === 'partial'
                                  ? 'bg-amber-100 text-amber-800'
                                  : 'bg-gray-200 text-gray-700')
                        }
                    >
                        {t('invoice.paymentState.' + paymentState)}
                    </span>
                </div>

                <table className="w-full border-collapse border border-gray-300">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colPayment')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.paymentDate')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colAllocated')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colStatus')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {allocRows.map((a) => {
                            const reversed = a.payments?.status === 'reversed'
                            return (
                                <tr key={a.id} className={reversed ? 'text-gray-400' : ''}>
                                    <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                        {a.payments ? (
                                            <Link
                                                href={`/finance/payments/${a.payments.id}`}
                                                className={
                                                    reversed
                                                        ? 'text-gray-400 hover:underline line-through'
                                                        : 'text-blue-600 hover:underline'
                                                }
                                            >
                                                {a.payments.code}
                                            </Link>
                                        ) : (
                                            '—'
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-sm">
                                        {a.payments?.payment_date ?? '—'}
                                    </td>
                                    <td
                                        className={
                                            'border border-gray-300 px-4 py-2 text-right font-mono text-sm' +
                                            (reversed ? ' line-through' : '')
                                        }
                                    >
                                        {formatUsd(a.allocated_usd)}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-sm">
                                        {reversed ? (
                                            <span className="px-2 py-1 rounded text-xs bg-gray-200 text-gray-500">
                                                {t('finance.reversedMark')}
                                            </span>
                                        ) : (
                                            <span className="px-2 py-1 rounded text-xs bg-green-100 text-green-800">
                                                {t('finance.status.posted')}
                                            </span>
                                        )}
                                    </td>
                                </tr>
                            )
                        })}
                        {allocRows.length === 0 && (
                            <tr>
                                <td colSpan={4} className="border border-gray-300 px-4 py-4 text-center text-gray-500 text-sm">
                                    {t('finance.noOpenItems')}
                                </td>
                            </tr>
                        )}
                    </tbody>
                </table>
            </section>
        </div>
    )
}
