'use client'

import { useActionState } from 'react'
import Link from 'next/link'
import { updateCustomer, type UpdateCustomerState } from './actions'
import { useTranslations } from '@/lib/i18n/client'

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
    contact_person: string | null
    email: string | null
    phone: string | null
    customer_types: string[] | null
    payment_terms: string | null
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

                {/* 联系方式(开票抬头会用到)*/}
                <fieldset className="border border-gray-200 rounded p-4">
                    <legend className="text-sm font-medium px-1">{t('customers.form.contactGroup')}</legend>
                    <div className="space-y-3">
                        <div>
                            <label className="block text-sm font-medium mb-1">{t('customers.form.contactPerson')}</label>
                            <input
                                type="text"
                                name="contact_person"
                                defaultValue={customer.contact_person ?? ''}
                                className="w-full border border-gray-300 px-3 py-2 rounded"
                            />
                        </div>
                        <div className="flex flex-wrap gap-3">
                            <div className="flex-1 min-w-[14rem]">
                                <label className="block text-sm font-medium mb-1">{t('customers.form.email')}</label>
                                <input
                                    type="text"
                                    name="email"
                                    defaultValue={customer.email ?? ''}
                                    className="w-full border border-gray-300 px-3 py-2 rounded"
                                />
                            </div>
                            <div className="flex-1 min-w-[12rem]">
                                <label className="block text-sm font-medium mb-1">{t('customers.form.phone')}</label>
                                <input
                                    type="text"
                                    name="phone"
                                    defaultValue={customer.phone ?? ''}
                                    className="w-full border border-gray-300 px-3 py-2 rounded"
                                />
                            </div>
                        </div>
                    </div>
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
                                    {c.code} · {c.name_zh} / {c.name_en}
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
                    <button
                        type="submit"
                        disabled={isPending}
                        className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                    >
                        {isPending ? t('common.saving') : t('common.save')}
                    </button>
                    <Link
                        href="/customers"
                        className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                    >
                        {t('common.cancel')}
                    </Link>
                </div>
            </form>
        </>
    )
}
