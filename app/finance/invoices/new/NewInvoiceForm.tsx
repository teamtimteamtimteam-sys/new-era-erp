'use client'

// 开票表单:选客户 → 勾选其待开票销售(外加"未记录客户"的那批,它们可以开给所选客户)
// → 期限/条款 → 提交。底部实时合计;混币种时直接禁用提交(DB 的 MIXED_CURRENCY 兜底)。
import { useActionState, useMemo, useState } from 'react'
import Link from 'next/link'
import { createInvoice, type CreateInvoiceState } from './actions'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { formatAmount, formatMoneyBare } from '@/lib/format'
import DecimalInput from '@/app/components/forms/DecimalInput'

const initialState: CreateInvoiceState = {}

// 发票【一律用英文开具】(既定决策)。terms_text 是【存进单据的正文】,不是界面标签,
// 所以它绝不能跟着操作者的界面语言走 —— 界面切成中文时开票,不应该给英文客户寄去中文条款。
// 因此默认条款写死成英文常量,不进 messages/*.ts。字段本身仍可自由编辑。
const defaultTermsText = (days: number) =>
    `Payment due within ${days} days of invoice date.`

export type CustomerOption = {
    id: string
    name: string
    payment_terms_days: number | null
    // GST-2:这个客户的默认销项税码。**null 不是一个默认值,是一个没有人
    // 回答过的问题** —— 已注册时开票会按名拒(TAX_CODE_REQUIRED)。
    default_tax_code: string | null
}

export type TaxCodeOption = { code: string; name_en: string; name_zh: string }

export type TaxRateRow = {
    tax_code: string
    rate_pct: number
    effective_from: string
    effective_to: string | null
}

// 【与 tax_rate_for(code, date) 逐字同一条判据】按【生效期间】解析,不回退、
// 不取最近的一条。找不到就返回 null,而屏幕上说"这一天没有在册税率" ——
// 前端预览必须与数据库的答案一致,否则人看到一个数、存下来的是一次拒绝。
function rateFor(rates: TaxRateRow[], code: string, date: string): number | null {
    const hit = rates.find(
        (r) => r.tax_code === code && date >= r.effective_from &&
               (r.effective_to === null || date <= r.effective_to))
    return hit ? hit.rate_pct : null
}

export type SaleOption = {
    sales_record_id: string
    customer_id: string | null
    batch_code: string
    material_name: string | null
    sale_date: string
    quantity: number
    unit: string
    unit_price: number
    currency: string
    amount_base: number
}

function todayIsoLocal(): string {
    const d = new Date()
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

function addDays(iso: string, days: number): string {
    const d = new Date(iso + 'T00:00:00')
    if (Number.isNaN(d.getTime())) return ''
    d.setDate(d.getDate() + days)
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

const round2 = (n: number) => Math.round(n * 100) / 100

export default function NewInvoiceForm({
    customers,
    sales,
    gstRegistered,
    taxCodes,
    taxRates,
}: {
    customers: CustomerOption[]
    sales: SaleOption[]
    gstRegistered: boolean
    taxCodes: TaxCodeOption[]
    taxRates: TaxRateRow[]
}) {
    const t = useTranslations()
    const locale = useLocale()
    const [state, formAction, isPending] = useActionState(createInvoice, initialState)

    const [customerId, setCustomerId] = useState('')
    const [issueDate, setIssueDate] = useState(todayIsoLocal())
    const [termsDays, setTermsDays] = useState('')
    const [termsTouched, setTermsTouched] = useState(false)
    const [termsText, setTermsText] = useState('')
    const [termsTextTouched, setTermsTextTouched] = useState(false)
    const [checked, setChecked] = useState<Record<string, boolean>>({})
    // 【税码:客户的默认是一个【建议】,不是一个悄悄的替代】它显示在框里、
    // 可以当场改;而客户没设默认时这里是空的,提交会撞上具名拒绝而不是一个猜测。
    const [taxCode, setTaxCode] = useState('')
    const [taxCodeTouched, setTaxCodeTouched] = useState(false)

    const customer = customers.find((c) => c.id === customerId)

    // 账期:未手改过就跟随所选客户(客户没设则 30)
    const effTerms = termsTouched
        ? termsDays
        : String(customer?.payment_terms_days ?? 30)
    const termsNum = Number(effTerms)
    const dueDate =
        effTerms !== '' && !Number.isNaN(termsNum) ? addDays(issueDate, termsNum) : ''

    // 发票条款:未手改过就用英文默认句式,并随天数实时重算;
    // 一旦 Tim 自己动过(termsTextTouched),就再也不覆盖他输入的内容。
    const effTermsText = termsTextTouched
        ? termsText
        : defaultTermsText(Number.isNaN(termsNum) ? 30 : termsNum)

    // 该客户的待开票销售 + 无主销售(可以开给所选客户)
    const visible = useMemo(() => {
        if (!customerId) return []
        return sales.filter((s) => s.customer_id === customerId || s.customer_id === null)
    }, [sales, customerId])

    function onCustomerChange(id: string) {
        setCustomerId(id)
        setChecked({}) // 换客户清空勾选,避免把别人的销售带过去
        setTaxCodeTouched(false) // 税码回到新客户的默认(没设就是空)
    }

    const selected = visible.filter((s) => checked[s.sales_record_id])
    const subtotal = round2(selected.reduce((sum, s) => sum + s.amount_base, 0))
    const currencies = Array.from(new Set(selected.map((s) => s.currency)))
    const mixedCurrency = currencies.length > 1
    // 【税码:未手改过就跟随客户的默认】
    const effTaxCode = taxCodeTouched ? taxCode : (customer?.default_tax_code ?? '')
    // 【税率按【开票日】解析,不是按今天】开票日在这张表单上可以改,
    // 而 2022 年那张票永远是 7% —— 预览必须跟着日期走。
    const resolvedRate = gstRegistered && effTaxCode
        ? rateFor(taxRates, effTaxCode, issueDate)
        : null
    const rateMissing = gstRegistered && !!effTaxCode && resolvedRate === null
    const taxRate = resolvedRate ?? 0
    // 【逐行取整再相加 —— 与 create_invoice 同一口径】表头 = Σ 行税。
    const tax = gstRegistered && resolvedRate !== null
        ? round2(selected.reduce((sum, s) => sum + round2((s.amount_base * taxRate) / 100), 0))
        : 0
    const total = round2(subtotal + tax)

    const canSubmit = !!customerId && selected.length > 0 && !mixedCurrency && !isPending
        // 【已注册就必须有一个税码,而且那一天必须有在册税率】两者都在数据库上
        // 有具名拒绝;这里提前禁用,是为了不把人骗去撞一次拒绝(CMP-2)。
        && !(gstRegistered && (!effTaxCode || rateMissing))

    return (
        <form action={formAction} className="space-y-5">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}

            <input type="hidden" name="terms_days" value={effTerms} />
            <input type="hidden" name="terms_text" value={effTermsText} />

            <div className="flex flex-wrap gap-4">
                <div className="flex-1 min-w-[18rem]">
                    <label className="block text-sm font-medium mb-1">
                        {t('invoice.form.customer')} <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="customer_id"
                        required
                        value={customerId}
                        onChange={(e) => onCustomerChange(e.target.value)}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="" disabled>
                            {t('invoice.form.selectCustomer')}
                        </option>
                        {customers.map((c) => (
                            <option key={c.id} value={c.id}>
                                {c.name}
                            </option>
                        ))}
                    </select>
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('invoice.form.issueDate')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="date"
                        name="issue_date"
                        required
                        value={issueDate}
                        onChange={(e) => setIssueDate(e.target.value)}
                        className="border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">{t('invoice.form.termsDays')}</label>
                    <DecimalInput
                        value={effTerms}
                        onChange={(raw) => {
                            setTermsTouched(true)
                            setTermsDays(raw)
                        }}
                        className="w-24 border border-gray-300 px-3 py-2 rounded"
                    />
                    {dueDate && (
                        <p className="text-xs text-gray-500 mt-1">
                            {t('invoice.form.dueDatePreview', { date: dueDate })}
                        </p>
                    )}
                </div>
                {/* ★【GST-2:税码 —— 只在已注册时出现】★ 未注册时这张表单与
                    建 GST 之前一模一样,连这一格都不该长出来。 */}
                {gstRegistered && (
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {t('invoice.form.taxCode')} <span className="text-red-600">*</span>
                        </label>
                        <select
                            name="tax_code"
                            value={effTaxCode}
                            onChange={(e) => { setTaxCodeTouched(true); setTaxCode(e.target.value) }}
                            className="border border-gray-300 px-3 py-2 rounded"
                        >
                            <option value="">{t('invoice.form.taxCodePick')}</option>
                            {taxCodes.map((c) => (
                                <option key={c.code} value={c.code}>
                                    {/* 【按界面语言选一个,不是把两个拼起来】与仓库里另外 105 处同一个写法。
                                        拼接在中文界面下勉强能读,在英文界面下就是把中文推给一个读不懂它的人。 */}
                                    {c.code} · {locale === 'zh' ? c.name_zh : c.name_en}
                                </option>
                            ))}
                        </select>
                        {/* 【说出这个码是【从哪儿来的】,不让它看起来像凭空出现的】 */}
                        {!taxCodeTouched && customer?.default_tax_code && (
                            <p className="text-xs text-gray-500 mt-1">
                                {t('invoice.form.taxCodeFromCustomer', { code: customer.default_tax_code })}
                            </p>
                        )}
                        {!!customerId && !customer?.default_tax_code && !effTaxCode && (
                            <p className="text-xs text-amber-700 mt-1">{t('invoice.form.taxCodeNoDefault')}</p>
                        )}
                        {rateMissing && (
                            <p className="text-xs text-red-600 mt-1">
                                {t('invoice.form.taxRateMissing', { code: effTaxCode, date: issueDate })}
                            </p>
                        )}
                    </div>
                )}
            </div>

            {/* 待开票销售 */}
            <div>
                <h2 className="text-lg font-semibold mb-2">{t('invoice.form.sales')}</h2>
                {!customerId ? (
                    <p className="text-sm text-gray-500">{t('invoice.form.selectCustomer')}</p>
                ) : visible.length === 0 ? (
                    <p className="text-sm text-gray-500">{t('invoice.form.noSales')}</p>
                ) : (
                    <table className="w-full border-collapse border border-gray-300">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-3 py-2 w-8" />
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('invoice.colDescription')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('finance.colDate')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-right">{t('invoice.colQuantity')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-right">{t('invoice.colUnitPrice')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-right">{t('invoice.colAmount')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {visible.map((s) => (
                                <tr key={s.sales_record_id}>
                                    <td className="border border-gray-300 px-3 py-2 text-center">
                                        <input
                                            type="checkbox"
                                            checked={!!checked[s.sales_record_id]}
                                            onChange={(e) =>
                                                setChecked((c) => ({
                                                    ...c,
                                                    [s.sales_record_id]: e.target.checked,
                                                }))
                                            }
                                        />
                                        {checked[s.sales_record_id] && (
                                            <input type="hidden" name="sale_id" value={s.sales_record_id} />
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 text-sm">
                                        <span className="font-mono">{s.batch_code}</span>
                                        {s.material_name && <span className="ml-2">{s.material_name}</span>}
                                        {s.customer_id === null && (
                                            <span className="ml-2 px-2 py-0.5 rounded text-xs bg-amber-100 text-amber-800">
                                                {t('invoice.unassignedSale')}
                                            </span>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 text-sm">{s.sale_date}</td>
                                    <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                        {s.quantity} {s.unit}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                        {s.currency} {formatMoneyBare(s.unit_price, '同格内紧邻的 s.currency 前缀')}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                        {formatAmount(s.amount_base, s.currency)}
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                )}
            </div>

            <div className="flex flex-wrap gap-4">
                <div className="flex-1 min-w-[16rem]">
                    <label className="block text-sm font-medium mb-1">{t('invoice.form.notes')}</label>
                    <input
                        type="text"
                        name="notes"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                <div className="flex-1 min-w-[20rem]">
                    <label className="block text-sm font-medium mb-1">{t('invoice.form.termsText')}</label>
                    <input
                        type="text"
                        value={effTermsText}
                        onChange={(e) => {
                            setTermsTextTouched(true)
                            setTermsText(e.target.value)
                        }}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
            </div>

            {/* 实时合计 */}
            <div className="bg-gray-50 rounded p-4 max-w-sm ml-auto text-sm space-y-1">
                <div className="flex justify-between">
                    <span className="text-gray-600">{t('invoice.form.selectedCount', { n: selected.length })}</span>
                </div>
                <div className="flex justify-between">
                    <span className="text-gray-600">{t('invoice.subtotal')}</span>
                    <span className="font-mono">{formatAmount(subtotal, currencies[0] ?? null)}</span>
                </div>
                {/* 税行只在已做 GST 登记时出现 */}
                {gstRegistered && (
                    <div className="flex justify-between">
                        {/* 【印的是【解析出来的】税率,连它是哪个码一起说】—— 一个
                            光秃秃的百分数说不出 0% 是零税率、豁免还是不在范围内。 */}
                        <span className="text-gray-600">
                            {effTaxCode && !rateMissing
                                ? t('invoice.taxWithCode', { code: effTaxCode, rate: taxRate })
                                : t('invoice.taxUnresolved')}
                        </span>
                        <span className="font-mono">
                            {effTaxCode && !rateMissing ? formatAmount(tax, currencies[0] ?? null) : '—'}
                        </span>
                    </div>
                )}
                <div className="flex justify-between border-t pt-1 font-bold">
                    <span>{t('invoice.total')}</span>
                    <span className="font-mono">{formatAmount(total, currencies[0] ?? null)}</span>
                </div>
            </div>

            {mixedCurrency && (
                <p className="text-red-600 text-sm text-right">{t('invoice.mixedCurrency')}</p>
            )}

            <div className="flex gap-3 pt-2">
                <button
                    type="submit"
                    disabled={!canSubmit}
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {isPending ? t('invoice.form.submitting') : t('invoice.form.submit')}
                </button>
                <Link href="/finance/invoices" className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50">
                    {t('common.cancel')}
                </Link>
            </div>
        </form>
    )
}
