'use client'

import { useActionState } from 'react'
import Link from 'next/link'
import { updateSupplier, type UpdateSupplierState } from './actions'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { SUPPLIER_TYPE_OPTIONS } from '../../supplierTypes'

const initialState: UpdateSupplierState = {}

type Supplier = {
    id: string
    legal_name: string
    short_name: string | null
    country: string
    tax_id: string | null
    address: string | null
    supplier_types: string[] | null
    counterparty_type: string | null
    default_tax_code: string | null
    tax_residence: string | null
    payment_terms: string | null
    incoterm: string | null
    credit_rating: string | null
    notes: string | null
    default_payment_term_template_id: string | null
}

export type TemplateOption = { id: string; name: string }

export type TaxCodeOption = { code: string; name_en: string; name_zh: string }

export default function EditSupplierForm({
    supplier,
    templates,
    gstRegistered,
    taxCodes,
}: {
    supplier: Supplier
    templates: TemplateOption[]
    gstRegistered: boolean
    taxCodes: TaxCodeOption[]
}) {
    const t = useTranslations()
    const locale = useLocale()
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

                {/* LOG-1a:【这一家是什么】。取代了原来那个 supplies_goods 复选框 ——
                    那一列现在是本选择的【派生列】,写不得。
                    三选一而不是勾选,是因为问题不再是二元的:货代与房东/水电
                    都"不供货",但前者不该出现在供应商名单里,后者要留在费用选择器里。 */}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('suppliers.counterpartyType')} <span className="text-red-600">*</span>
                    </label>
                    <select name="counterparty_type" defaultValue={supplier.counterparty_type ?? 'goods_supplier'} className="w-full border border-gray-300 px-3 py-2 rounded">
                        <option value="goods_supplier">{t('suppliers.type.goods_supplier')}</option>
                        <option value="forwarder">{t('suppliers.type.forwarder')}</option>
                        <option value="service_vendor">{t('suppliers.type.service_vendor')}</option>
                    </select>
                    <p className="text-xs text-gray-500 mt-1 max-w-2xl">
                        {t('suppliers.counterpartyTypeHint')}
                    </p>
                </div>

                {/* ★【WHT-1:税务居民身份 —— 它【不是】上面那个 country】★
                    这一栏是整条预提税链的【前置条件】:没有它,付给这一家的款
                    永远不会被追问代扣。所以它必须有一个入口 —— 一个没有入口的
                    字段等于这个功能不存在(SAL-B6 的客户页就是这么无门上线的)。
                    【三态,而 NULL 不是"居民"】留空 = 没有人回答过,
                    与"申报为居民"在账上的后果完全不同:前者不追问、后者明确不代扣。 */}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('suppliers.form.taxResidence')}
                    </label>
                    <select
                        name="tax_residence"
                        defaultValue={supplier.tax_residence ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="">{t('suppliers.form.taxResidenceUnstated')}</option>
                        <option value="resident">{t('suppliers.form.taxResidenceResident')}</option>
                        <option value="non_resident">{t('suppliers.form.taxResidenceNonResident')}</option>
                    </select>
                    <p className="text-xs text-gray-500 mt-1 max-w-2xl">{t('suppliers.form.taxResidenceHint')}</p>
                </div>

                {/* ★【GST-2:这家供应商的默认进项税码 —— 只在已注册时出现】★ */}
                {gstRegistered && (
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('suppliers.form.defaultTaxCode')}</label>
                        <select
                            name="default_tax_code"
                            defaultValue={supplier.default_tax_code ?? ''}
                            className="w-full border border-gray-300 px-3 py-2 rounded"
                        >
                            <option value="">{t('suppliers.form.defaultTaxCodeNone')}</option>
                            {taxCodes.map((c) => (
                                <option key={c.code} value={c.code}>
                                    {/* 【按界面语言选一个,不是把两个拼起来】与仓库里另外 105 处同一个写法。
                                        拼接在中文界面下勉强能读,在英文界面下就是把中文推给一个读不懂它的人。 */}
                                    {c.code} · {locale === 'zh' ? c.name_zh : c.name_en}
                                </option>
                            ))}
                        </select>
                        <p className="text-xs text-gray-500 mt-1 max-w-2xl">{t('suppliers.form.defaultTaxCodeHint')}</p>
                    </div>
                )}

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
