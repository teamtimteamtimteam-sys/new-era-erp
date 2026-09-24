'use client'

// 开票表单:选客户 → 勾选其待开票销售(外加"未记录客户"的那批,它们可以开给所选客户)
// → 期限/条款 → 提交。底部实时合计;混币种时直接禁用提交(DB 的 MIXED_CURRENCY 兜底)。
import { CONTROL_CHECKBOX, CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useActionState, useMemo, useState } from 'react'
import Link from 'next/link'
import { createInvoice, type CreateInvoiceState } from './actions'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { formatAmount, formatMoneyBare } from '@/lib/format'
import DecimalInput from '@/app/components/forms/DecimalInput'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { EditableTable, type EditableColumn } from '@/app/components/ui/editable-table'
import { formatDate } from '@/lib/dates'
import { businessToday } from '@/lib/format'

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
canEdit
}: {
    customers: CustomerOption[]
    sales: SaleOption[]
    gstRegistered: boolean
    taxCodes: TaxCodeOption[]
    taxRates: TaxRateRow[]

canEdit: boolean
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

    /* ★★ 桥的载荷。**只送勾中的那些** —— 与搬家前逐字同构:
       那个具名隐藏输入搬家前就是条件渲染的(`{checked[…] && <input name="sale_id">}`),
       所以数组里本来就只有勾中的行。
       ★ 这一座桥**不是**按下标配对的那一族:服务端读的是
       `getAll('sale_id').filter(Boolean)` —— 一份单纯的 id 名单,没有第二条数组
       要跟它对齐。**所以这一张本来就没有错位的风险**,照直记,
       免得下一个人以为每一张表都带着 `SALES-AMEND-DISABLED-ARRAY-SHIFT` 那条病。 */
    const salePayload = visible
        .filter((s) => checked[s.sales_record_id])
        .map((s) => s.sales_record_id)

    /* ★ Q5 的必填 `dirty` —— 这张表单开局一票都没勾。 */
    const salesDirty = selected.length > 0

    /* ════════════════════════════════════════════════════════════════════════
       ★★★【勾选框【就是】这张表的可编辑列 —— Tim 的 Q2 裁定(DRAFT-5)】★★★
       这张表**一个要打字的格子都没有**,而 `EditableTable` 对「一列都不可编辑」
       是按名拒绝的(`EDITABLETABLE_NO_EDITABLE_COLUMN`:那是 `DataTable` 的活)。
       ☞ 裁定:**勾一票【就是】在改这份草稿**,所以勾选框是 `edit`,
         `render` 画它的只读投影(✓ / —)。
       ⚠ ★★ **而这一条带来一个照直记的代价:** 旧注释写着
         「这张表【要点的就是第一列那个勾】—— 它必须留在看得见的地方」,
         而 `page-owned` 下**手机档的格子恒为只读**(`editable-table.tsx:676-679`),
         所以那个勾**在 390px 上从明面移进了展开区:0 → 1 次点按。**
         ☞ 这是 Tim 的 Q7 裁定在这一张上的又一次落地 ——
           **R1 不是被投票投掉的,是在这个组件上做不到。** 留在明面上的
           只会是一个**画出来却按不动**的勾。
       ★ 两列只读的数(数量 / 单价)照旧叠进品名那一格 —— 零次点按。
       ════════════════════════════════════════════════════════════════════════ */
    const saleColumns: EditableColumn<SaleOption, SaleOption>[] = [
        {
            key: 'pick',
            header: '',
            priority: true,
            render: (s) => (checked[s.sales_record_id]
                ? <span aria-label={t('common.yes')}>✓</span>
                : <span className="text-gray-400" aria-label={t('common.no')}>—</span>),
            edit: (s) => (
                <input
                    className={CONTROL_CHECKBOX}
                    type="checkbox"
                    aria-label={s.batch_code}
                    checked={!!checked[s.sales_record_id]}
                    onChange={(e) =>
                        setChecked((c) => ({ ...c, [s.sales_record_id]: e.target.checked }))
                    }
                />
            ),
        },
        {
            key: 'description',
            header: t('invoice.colDescription'),
            priority: true,
            render: (s) => (
                <>
                    <span>{s.batch_code}</span>
                    {s.material_name && <span className="ml-2">{s.material_name}</span>}
                    {s.customer_id === null && (
                        <span className="ml-2 px-2 py-0.5 rounded text-xs bg-amber-100 text-amber-800">
                            {t('invoice.unassignedSale')}
                        </span>
                    )}
                    {/* ★ TABLE-PHONE-4:手机档拿掉的两列,原样叠在这里 ——
                        「拿掉」指的是【那一列】,不是【那个事实】。
                        带着各自的列头,所以数字不会失去主语。 */}
                    <div className="sm:hidden mt-1 space-y-0.5 font-sans text-xs text-gray-600">
                        <div>
                            <span className="font-sans text-gray-500">{t('invoice.colQuantity')}: </span>
                            {s.quantity} {s.unit}
                        </div>
                        <div>
                            <span className="font-sans text-gray-500">{t('invoice.colUnitPrice')}: </span>
                            {s.currency} {formatMoneyBare(s.unit_price, '同格内紧邻的 s.currency 前缀')}
                        </div>
                    </div>
                </>
            ),
        },
        {
            key: 'date',
            header: t('finance.colDate'),
            priority: true,
            render: (s) => formatDate(s.sale_date, locale),
        },
        {
            key: 'quantity',
            header: t('invoice.colQuantity'),
            align: 'right',
            render: (s) => <>{s.quantity} {s.unit}</>,
        },
        {
            key: 'unitPrice',
            header: t('invoice.colUnitPrice'),
            align: 'right',
            render: (s) => <>{s.currency} {formatMoneyBare(s.unit_price, '同格内紧邻的 s.currency 前缀')}</>,
        },
        {
            key: 'amount',
            header: t('invoice.colAmount'),
            align: 'right',
            priority: true,
            render: (s) => formatAmount(s.amount_base, s.currency),
        },
    ]
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
        <PermissionGate code="module.finance.edit" allowed={canEdit}>
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
                    <label className="block mb-1">
                        {t('invoice.form.customer')} <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="customer_id"
                        required
                        value={customerId}
                        onChange={(e) => onCustomerChange(e.target.value)}
                        className={`${CONTROL_SELECT} w-full`}
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
                    <label className="block mb-1">
                        {t('invoice.form.issueDate')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="date"
                        name="issue_date"
                        required
                        max={businessToday()}
                        value={issueDate}
                        onChange={(e) => setIssueDate(e.target.value)}
                        className={CONTROL_INPUT}
                    />
                </div>
                <div>
                    <label className="block mb-1">{t('invoice.form.termsDays')}</label>
                    <DecimalInput
                        value={effTerms}
                        onChange={(raw) => {
                            setTermsTouched(true)
                            setTermsDays(raw)
                        }}
                        className="w-24"
                    />
                    {dueDate && (
                        <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">
                            {t('invoice.form.dueDatePreview', { date: dueDate })}
                        </p>
                    )}
                </div>
                {/* ★【GST-2:税码 —— 只在已注册时出现】★ 未注册时这张表单与
                    建 GST 之前一模一样,连这一格都不该长出来。 */}
                {gstRegistered && (
                    <div>
                        <label className="block mb-1">
                            {t('invoice.form.taxCode')} <span className="text-red-600">*</span>
                        </label>
                        <select
                            name="tax_code"
                            value={effTaxCode}
                            onChange={(e) => { setTaxCodeTouched(true); setTaxCode(e.target.value) }}
                            className={CONTROL_SELECT}
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
                            <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">
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
                <h2 className="mb-2">{t('invoice.form.sales')}</h2>
                {!customerId ? (
                    <p className="text-sm text-[color:var(--brand-muted-text)]">{t('invoice.form.selectCustomer')}</p>
                ) : visible.length === 0 ? (
                    <p className="text-sm text-[color:var(--brand-muted-text)]">{t('invoice.form.noSales')}</p>
                ) : (
                    <>
                        {/* ★★ (b) 那座桥 —— 画在表外面,只画一遍。
                            ★ 它交出去的是一份**单纯的 id 名单**,不是按下标配对的行;
                              服务端那一侧原本就是 `getAll('sale_id').filter(Boolean)`。 */}
                        <input type="hidden" name="sale_ids_json" value={JSON.stringify(salePayload)} />
                        <EditableTable<SaleOption, SaleOption>
                            rows={visible}
                            columns={saleColumns}
                            rowKey={(s) => s.sales_record_id}
                            phone={{ mode: 'columns' }}
                            mode="page-owned"
                            dirty={salesDirty}
                            labels={{ expand: t('common.expandRow') }}
                        />
                    </>
                )}
            </div>

            <div className="flex flex-wrap gap-4">
                <div className="flex-1 min-w-[16rem]">
                    <label className="block mb-1">{t('invoice.form.notes')}</label>
                    <input
                        type="text"
                        name="notes"
                        className={`${CONTROL_INPUT} w-full`}
                    />
                </div>
                <div className="flex-1 min-w-[20rem]">
                    <label className="block mb-1">{t('invoice.form.termsText')}</label>
                    <input
                        type="text"
                        value={effTermsText}
                        onChange={(e) => {
                            setTermsTextTouched(true)
                            setTermsText(e.target.value)
                        }}
                        className={`${CONTROL_INPUT} w-full`}
                    />
                </div>
            </div>

            {/* 实时合计 */}
            <div className="bg-gray-50 rounded p-4 max-w-sm ml-auto text-sm space-y-1">
                <div className="flex justify-between">
                    <span className="text-[color:var(--brand-muted-text)]">{t('invoice.form.selectedCount', { n: selected.length })}</span>
                </div>
                <div className="flex justify-between">
                    <span className="text-[color:var(--brand-muted-text)]">{t('invoice.subtotal')}</span>
                    <span>{formatAmount(subtotal, currencies[0] ?? null)}</span>
                </div>
                {/* 税行只在已做 GST 登记时出现 */}
                {gstRegistered && (
                    <div className="flex justify-between">
                        {/* 【印的是【解析出来的】税率,连它是哪个码一起说】—— 一个
                            光秃秃的百分数说不出 0% 是零税率、豁免还是不在范围内。 */}
                        <span className="text-[color:var(--brand-muted-text)]">
                            {effTaxCode && !rateMissing
                                ? t('invoice.taxWithCode', { code: effTaxCode, rate: taxRate })
                                : t('invoice.taxUnresolved')}
                        </span>
                        <span>
                            {effTaxCode && !rateMissing ? formatAmount(tax, currencies[0] ?? null) : '—'}
                        </span>
                    </div>
                )}
                <div className="flex justify-between border-t pt-1 font-bold">
                    <span>{t('invoice.total')}</span>
                    <span>{formatAmount(total, currencies[0] ?? null)}</span>
                </div>
            </div>

            {mixedCurrency && (
                <p className="text-red-600 text-sm text-right tabular-nums">{t('invoice.mixedCurrency')}</p>
            )}

            <div className="flex gap-3 pt-2">
                <Button
                    type="submit"
                    disabled={!canSubmit}
                >
                    {isPending ? t('invoice.form.submitting') : t('invoice.form.submit')}
                </Button>
                <Button asChild variant="secondary">
                    <Link href="/finance/invoices">
                        {t('common.cancel')}
                    </Link>
                </Button>
            </div>
        </form>
        </PermissionGate>
    )
}
