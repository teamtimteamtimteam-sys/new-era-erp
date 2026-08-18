'use client'

import { useActionState } from 'react'
import Link from 'next/link'
import { updateSupplier, type UpdateSupplierState } from './actions'
import { useTranslations } from '@/lib/i18n/client'

const SUPPLIER_TYPE_OPTIONS = [
    { value: 'dismantler', labelKey: 'suppliers.types.dismantler' },
    { value: 'battery_factory_scrap', labelKey: 'suppliers.types.batteryScrap' },
    { value: 'recycler', labelKey: 'suppliers.types.recycler' },
    { value: 'trader', labelKey: 'suppliers.types.trader' },
]

const initialState: UpdateSupplierState = {}

type Supplier = {
    id: string
    legal_name: string
    short_name: string | null
    country: string
    tax_id: string | null
    address: string | null
    supplier_types: string[] | null
    supplies_goods: boolean | null
    payment_terms: string | null
    incoterm: string | null
    credit_rating: string | null
    notes: string | null
    default_payment_term_template_id: string | null
}

export type TemplateOption = { id: string; name: string }

export default function EditSupplierForm({
    supplier,
    templates,
}: {
    supplier: Supplier
    templates: TemplateOption[]
}) {
    const t = useTranslations()
    const updateWithId = updateSupplier.bind(null, supplier.id)
    const [state, formAction, isPending] = useActionState(
        updateWithId,
        initialState
    )

    const currentTypes = supplier.supplier_types ?? []

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
                        {t('suppliers.form.legalName')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="legal_name"
                        required
                        defaultValue={supplier.legal_name}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                    {state.fieldErrors?.legal_name && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.legal_name}
                        </p>
                    )}
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('suppliers.form.shortName')}</label>
                    <input
                        type="text"
                        name="short_name"
                        defaultValue={supplier.short_name ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('suppliers.form.country')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="country"
                        required
                        maxLength={2}
                        defaultValue={supplier.country}
                        className="w-full border border-gray-300 px-3 py-2 rounded uppercase"
                    />
                    {state.fieldErrors?.country && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.country}
                        </p>
                    )}
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('suppliers.form.taxId')}</label>
                    <input
                        type="text"
                        name="tax_id"
                        defaultValue={supplier.tax_id ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('suppliers.form.address')}</label>
                    <textarea
                        name="address"
                        rows={2}
                        defaultValue={supplier.address ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                <div>
                    <label className="block text-sm font-medium mb-2">
                        {t('suppliers.form.types')}
                    </label>
                    <div className="space-y-2">
                        {SUPPLIER_TYPE_OPTIONS.map((opt) => (
                            <label key={opt.value} className="flex items-center gap-2">
                                <input
                                    type="checkbox"
                                    name="supplier_types"
                                    value={opt.value}
                                    defaultChecked={currentTypes.includes(opt.value)}
                                    className="w-4 h-4"
                                />
                                <span className="text-sm">{t(opt.labelKey)}</span>
                            </label>
                        ))}
                    </div>
                </div>

                {/* SUP-TYPE-1b:【会不会从这一家收到货】—— 1a 加了这一列,但没有
                    任何表单能设它,于是它只能靠直接改库。一个只有默认值、没人
                    改得动的开关,等于没有这个能力。
                    【它不是 supplier_types】那一列说的是"他们做哪一行",这一个
                    说的是"我们收不收他们的货"—— 1a 的迁移抬头写了三条理由。 */}
                <div>
                    <label className="flex items-center gap-2">
                        <input
                            type="checkbox"
                            name="supplies_goods"
                            value="on"
                            defaultChecked={supplier.supplies_goods !== false}
                            className="w-4 h-4"
                        />
                        <span className="text-sm font-medium">{t('suppliers.suppliesGoods')}</span>
                    </label>
                    <p className="text-xs text-gray-500 mt-1 max-w-2xl">
                        {t('suppliers.suppliesGoodsHint')}
                    </p>
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('suppliers.form.paymentTerms')}</label>
                    <input
                        type="text"
                        name="payment_terms"
                        defaultValue={supplier.payment_terms ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                {/* 默认付款条款模板(cut 4b:新建采购单时自动带入付款计划)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('suppliers.defaultPaymentTerms')}</label>
                    <select
                        name="default_payment_term_template_id"
                        defaultValue={supplier.default_payment_term_template_id ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="">{t('suppliers.defaultPaymentTermsNone')}</option>
                        {templates.map((tpl) => (
                            <option key={tpl.id} value={tpl.id}>
                                {tpl.name}
                            </option>
                        ))}
                    </select>
                    <p className="text-xs text-gray-500 mt-1">{t('suppliers.defaultPaymentTermsHint')}</p>
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('suppliers.form.incoterm')}</label>
                    <input
                        type="text"
                        name="incoterm"
                        defaultValue={supplier.incoterm ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('suppliers.form.creditRating')}</label>
                    <input
                        type="text"
                        name="credit_rating"
                        defaultValue={supplier.credit_rating ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('suppliers.form.notes')}</label>
                    <textarea
                        name="notes"
                        rows={3}
                        defaultValue={supplier.notes ?? ''}
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
                        href="/suppliers"
                        className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                    >
                        {t('common.cancel')}
                    </Link>
                </div>
            </form>
        </>
    )
}
