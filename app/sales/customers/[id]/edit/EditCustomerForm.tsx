'use client'

import { useActionState } from 'react'
import Link from 'next/link'
import { updateCustomer, type UpdateCustomerState } from './actions'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'

const CUSTOMER_TYPE_OPTIONS = [
    { value: 'cathode_maker', labelKey: 'customers.types.cathodeMaker' },
    { value: 'battery_factory', labelKey: 'customers.types.batteryFactory' },
    { value: 'trader', labelKey: 'customers.types.trader' },
    { value: 'other', labelKey: 'customers.types.other' },
]

const initialState: UpdateCustomerState = {}

type Customer = {
    id: string
    legal_name: string
    short_name: string | null
    country: string
    tax_id: string | null
    address: string | null
    customer_types: string[] | null
    payment_terms: string | null
    payment_terms_days: number | null
    incoterm: string | null
    credit_rating: string | null
    credit_limit_base: number | null
    default_tax_code: string | null
    credit_hold: boolean | null
    notes: string | null
}

export type TaxCodeOption = { code: string; name_en: string; name_zh: string }

export default function EditCustomerForm({ customer, gstRegistered, taxCodes }: {
    customer: Customer
    gstRegistered: boolean
    taxCodes: TaxCodeOption[]
}) {
    const t = useTranslations()
    const locale = useLocale()
    const updateWithId = updateCustomer.bind(null, customer.id)
    const [state, formAction, isPending] = useActionState(
        updateWithId,
        initialState
    )

    const currentTypes = customer.customer_types ?? []

    return (
        <>
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            <form action={formAction} className="space-y-4">
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('customers.form.legalName')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="legal_name"
                        required
                        defaultValue={customer.legal_name}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                    {state.fieldErrors?.legal_name && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.legal_name}
                        </p>
                    )}
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('customers.form.shortName')}</label>
                    <input
                        type="text"
                        name="short_name"
                        defaultValue={customer.short_name ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('customers.form.country')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="country"
                        required
                        maxLength={2}
                        defaultValue={customer.country}
                        className="w-full border border-gray-300 px-3 py-2 rounded uppercase"
                    />
                    {state.fieldErrors?.country && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.country}
                        </p>
                    )}
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('customers.form.taxId')}</label>
                    <input
                        type="text"
                        name="tax_id"
                        defaultValue={customer.tax_id ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('customers.form.address')}</label>
                    <textarea
                        name="address"
                        rows={2}
                        defaultValue={customer.address ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                {/* 【PARTY-1:这里【不再】编辑联系人,而缺席要具名】
                    一个对手方可以有好几个联系人,而这张表单一次只装得下一个 ——
                    "编辑那个联系人"在有三个联系人的时候是一句没有意义的话。
                    联系人在客户页上维护(增删改、指定主联系人)。 */}
                <fieldset className="border border-gray-200 rounded p-4">
                    <legend className="text-sm font-medium px-1">{t('customers.form.contactGroup')}</legend>
                    <p className="text-xs text-gray-600">{t('customers.form.contactsMovedHint')}</p>
                </fieldset>

                <div>
                    <label className="block text-sm font-medium mb-2">
                        {t('customers.form.types')}
                    </label>
                    <div className="space-y-2">
                        {CUSTOMER_TYPE_OPTIONS.map((opt) => (
                            <label key={opt.value} className="flex items-center gap-2">
                                <input
                                    type="checkbox"
                                    name="customer_types"
                                    value={opt.value}
                                    defaultChecked={currentTypes.includes(opt.value)}
                                    className="w-4 h-4"
                                />
                                <span className="text-sm">{t(opt.labelKey)}</span>
                            </label>
                        ))}
                    </div>
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('customers.form.paymentTerms')}</label>
                    <input
                        type="text"
                        name="payment_terms"
                        defaultValue={customer.payment_terms ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">{t('customers.form.paymentTermsDays')}</label>
                    <input
                        type="number"
                        min="0"
                        name="payment_terms_days"
                        defaultValue={customer.payment_terms_days ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                    {/* CASHFLOW-1:这一列【已经被读了】—— 开票表单拿它当默认账期,
                        读不到就悄悄用 30 天。而在此之前【没有任何地方设得了它】,
                        于是一个 60 天账期的客户一直在拿 30 天的发票。
                        这里补的是那扇缺掉的门,不是第二扇:自由文本的 payment_terms
                        本来就在上面那一格里。 */}
                    <p className="text-xs text-gray-500 mt-1">{t('customers.form.paymentTermsDaysHint')}</p>
                </div>


                <div>
                    <label className="block text-sm font-medium mb-1">{t('customers.form.incoterm')}</label>
                    <input
                        type="text"
                        name="incoterm"
                        defaultValue={customer.incoterm ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('customers.form.creditRating')}</label>
                    <input
                        type="text"
                        name="credit_rating"
                        defaultValue={customer.credit_rating ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('customers.form.creditLimit')}</label>
                    {/* SAL-B:【留空 = 没设限额(放行);0 = 现款现货(任何赊销都拒)——
                        相反,不是相近】。全部既有客户为空:管控按客户逐个启用。 */}
                    <input
                        type="number"
                        step="0.01"
                        min="0"
                        name="credit_limit_base"
                        defaultValue={customer.credit_limit_base ?? ''}
                        placeholder={t('customers.form.creditLimitPlaceholder')}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                    <p className="text-xs text-gray-500 mt-1">{t('customers.form.creditLimitHint')}</p>
                </div>

                <div>
                    <label className="inline-flex items-center gap-2 text-sm font-medium">
                        <input type="checkbox" name="credit_hold" defaultChecked={customer.credit_hold ?? false} />
                        {t('customers.form.creditHold')}
                    </label>
                    <p className="text-xs text-gray-500 mt-1">{t('customers.form.creditHoldHint')}</p>
                </div>

                {/* ★【GST-2:这个客户的默认销项税码 —— 只在已注册时出现】★
                    未注册时这一格根本不长出来:那时税码写不进任何地方,
                    留一个设得了却毫无作用的框,是在承诺一件做不到的事。 */}
                {gstRegistered && (
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('customers.form.defaultTaxCode')}</label>
                        <select
                            name="default_tax_code"
                            defaultValue={customer.default_tax_code ?? ''}
                            className="w-full border border-gray-300 px-3 py-2 rounded"
                        >
                            <option value="">{t('customers.form.defaultTaxCodeNone')}</option>
                            {taxCodes.map((c) => (
                                <option key={c.code} value={c.code}>
                                    {/* 【按界面语言选一个,不是把两个拼起来】与仓库里另外 105 处同一个写法。
                                        拼接在中文界面下勉强能读,在英文界面下就是把中文推给一个读不懂它的人。 */}
                                    {c.code} · {locale === 'zh' ? c.name_zh : c.name_en}
                                </option>
                            ))}
                        </select>
                        <p className="text-xs text-gray-500 mt-1">{t('customers.form.defaultTaxCodeHint')}</p>
                    </div>
                )}

                <div>
                    <label className="block text-sm font-medium mb-1">{t('customers.form.notes')}</label>
                    <textarea
                        name="notes"
                        rows={3}
                        defaultValue={customer.notes ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                <div className="flex gap-3 pt-4">
                    <Button
                        type="submit"
                        disabled={isPending}
                    >
                        {isPending ? t('common.saving') : t('common.save')}
                    </Button>
                    <Link
                        href="/sales/customers"
                        className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                    >
                        {t('common.cancel')}
                    </Link>
                </div>
            </form>
        </>
    )
}
