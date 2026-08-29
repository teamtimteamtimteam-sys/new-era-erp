'use client'
// app/customers/new/NewCustomerForm.tsx
// OPS-15:本文件是原 page.tsx 的表单本体,原样搬过来 —— 一行渲染逻辑都没改。
// 搬家的理由只有一个:它是 'use client',而模块守卫 requireModule() 是服务端的
// (它 await 权限、读 cookie 取语言)。守卫塞进客户端组件会把 next/headers 拖进
// 客户端图,整个构建失败;而且客户端组件不能是 async。
// 所以守卫回到 page.tsx 那层服务端壳里,与 app/metal-prices/new 早就在用的形状一致。
import { useActionState } from 'react'
import { useRef } from 'react'
import { useFormDraft } from '@/lib/useFormDraft'
import DraftBanner from '@/app/components/DraftBanner'
import Link from 'next/link'
import { createCustomer, type CreateCustomerState } from './actions'
import { useTranslations } from '@/lib/i18n/client'

const CUSTOMER_TYPE_OPTIONS = [
    { value: 'cathode_maker', labelKey: 'customers.types.cathodeMaker' },
    { value: 'battery_factory', labelKey: 'customers.types.batteryFactory' },
    { value: 'trader', labelKey: 'customers.types.trader' },
    { value: 'other', labelKey: 'customers.types.other' },
]

const initialState: CreateCustomerState = {}

export default function NewCustomerForm() {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(
        createCustomer,
        initialState
    )

    // IDLE-DRAFT:草稿留存。受限与否由 lib/maskedTables.ts 推出来,
    // 不在这里声明 —— 见 lib/useFormDraft.ts 抬头。
    const formRef = useRef<HTMLFormElement>(null)
    const draft = useFormDraft({ formKey: 'customers/new', table: 'customers', subject: null, formRef })

    return (
        <div className="p-8 max-w-2xl">
            <div className="mb-6">
                <Link
                    href="/customers"
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-6">{t('customers.newTitle')}</h1>

            {/* 通用错误显示 */}
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            {/* GO-4:名字近重复的【提醒】—— 黄色不是红色,而且它【放行】。
                一个人推翻不了的警告,只是换了个友好颜色的拦截。
                再按一次提交就带上 ack_near_duplicate,服务端据此放行。 */}
            {state.nearDuplicateName && (
                <div className="bg-amber-50 border border-amber-400 text-amber-900 px-4 py-3 rounded mb-4">
                    {t('customers.form.errNearDuplicateName', { 0: state.nearDuplicateName })}
                </div>
            )}

            <form ref={formRef} action={formAction} className="space-y-4">
                <DraftBanner draft={draft} />
                {/* 提醒出现过之后才带上:带着它提交 = 已经读过并坚持要建 */}
                {state.nearDuplicateName && (
                    <input type="hidden" name="ack_near_duplicate" value="1" />
                )}
                {/* 法人名(必填) */}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('customers.form.legalName')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="legal_name"
                        required
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                        placeholder={t('customers.form.legalNamePlaceholder')}
                    />
                    {state.fieldErrors?.legal_name && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.legal_name}
                        </p>
                    )}
                </div>

                {/* 简称 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('customers.form.shortName')}</label>
                    <input
                        type="text"
                        name="short_name"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                        placeholder={t('customers.form.shortNamePlaceholder')}
                    />
                </div>

                {/* 国家(必填) */}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('customers.form.country')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="country"
                        required
                        maxLength={2}
                        className="w-full border border-gray-300 px-3 py-2 rounded uppercase"
                        placeholder={t('customers.form.countryPlaceholder')}
                    />
                    {state.fieldErrors?.country && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.country}
                        </p>
                    )}
                </div>

                {/* 税号 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('customers.form.taxId')}</label>
                    <input
                        type="text"
                        name="tax_id"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                {/* 地址 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('customers.form.address')}</label>
                    <textarea
                        name="address"
                        rows={2}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                {/* 【PARTY-1】这三个框写的是 counterparty_contacts 的【第一个联系人】,
                    不再是 customers 上的三列(它们已被搬走并删除)。
                    留在新建表单上是刻意的:建客户的时候手边就有这个人,
                    而"存完再去另一页加联系人"是一次没必要的往返。
                    【更多联系人在客户页上加】—— 那里才是一个对手方的联系人【们】。 */}
                <fieldset className="border border-gray-200 rounded p-4">
                    <legend className="text-sm font-medium px-1">{t('customers.form.contactGroup')}</legend>
                    <p className="text-xs text-gray-600 mb-3">{t('customers.form.contactGroupHint')}</p>
                    <div className="space-y-3">
                        <div>
                            <label className="block text-sm font-medium mb-1">{t('customers.form.contactPerson')}</label>
                            <input
                                type="text"
                                name="contact_person"
                                className="w-full border border-gray-300 px-3 py-2 rounded"
                            />
                        </div>
                        <div className="flex flex-wrap gap-3">
                            <div className="flex-1 min-w-[14rem]">
                                <label className="block text-sm font-medium mb-1">{t('customers.form.email')}</label>
                                <input
                                    type="text"
                                    name="email"
                                    className="w-full border border-gray-300 px-3 py-2 rounded"
                                />
                            </div>
                            <div className="flex-1 min-w-[12rem]">
                                <label className="block text-sm font-medium mb-1">{t('customers.form.phone')}</label>
                                <input
                                    type="text"
                                    name="phone"
                                    className="w-full border border-gray-300 px-3 py-2 rounded"
                                />
                            </div>
                        </div>
                    </div>
                </fieldset>

                {/* 客户类型(多选) */}
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
                                    className="w-4 h-4"
                                />
                                <span className="text-sm">{t(opt.labelKey)}</span>
                            </label>
                        ))}
                    </div>
                </div>

                {/* 付款条款 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('customers.form.paymentTerms')}</label>
                    <input
                        type="text"
                        name="payment_terms"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                        placeholder={t('customers.form.paymentTermsPlaceholder')}
                    />
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">{t('customers.form.paymentTermsDays')}</label>
                    <input
                        type="number"
                        min="0"
                        name="payment_terms_days"
                        
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                    {/* CASHFLOW-1:这一列【已经被读了】—— 开票表单拿它当默认账期,
                        读不到就悄悄用 30 天。而在此之前【没有任何地方设得了它】,
                        于是一个 60 天账期的客户一直在拿 30 天的发票。
                        这里补的是那扇缺掉的门,不是第二扇:自由文本的 payment_terms
                        本来就在上面那一格里。 */}
                    <p className="text-xs text-gray-500 mt-1">{t('customers.form.paymentTermsDaysHint')}</p>
                </div>


                {/* Incoterm */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('customers.form.incoterm')}</label>
                    <input
                        type="text"
                        name="incoterm"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                        placeholder={t('customers.form.incotermPlaceholder')}
                    />
                </div>

                {/* 信用评级 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('customers.form.creditRating')}</label>
                    <input
                        type="text"
                        name="credit_rating"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                        placeholder={t('customers.form.creditRatingPlaceholder')}
                    />
                </div>

                {/* 备注 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('customers.form.notes')}</label>
                    <textarea
                        name="notes"
                        rows={3}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                {/* 提交按钮 */}
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
        </div>
    )
}
