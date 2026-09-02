'use client'

// 定价公式表单(新建/编辑共用)。计价基准选 average 时才出现天数;
// 适用对象三选一,选中哪个才出现对应下拉。
// 下方计价比例表:七个金属各一行,【留空 = 该金属不计价】(保存时删除旧行)。
import { useActionState, useState } from 'react'
import { useRef } from 'react'
import { useFormDraft } from '@/lib/useFormDraft'
import DraftBanner from '@/app/components/DraftBanner'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import IndexPicker from '@/app/pricing/metal-prices/IndexPicker'
import type { MetalPriceIndex } from '@/app/pricing/metal-prices/indexOptions'
import DecimalInput from '@/app/components/forms/DecimalInput'
import type { MetalOption } from '@/app/pricing/metal-prices/options'
import type { FormulaState } from './actions'

const initialState: FormulaState = {}

export type PartyOption = { id: string; name: string }

export type FormulaDefaults = {
    name: string
    direction: string
    price_basis: string
    price_index: string | null
    average_days: string
    treatment_charge_usd_per_tonne: string
    flat_discount_pct: string
    supplier_id: string | null
    customer_id: string | null
    notes: string
    is_active: boolean
    payables: Record<string, string>
}

export const EMPTY_FORMULA: FormulaDefaults = {
    name: '',
    direction: 'both',
    price_basis: 'spot',
    price_index: null,
    average_days: '',
    treatment_charge_usd_per_tonne: '',
    flat_discount_pct: '',
    supplier_id: null,
    customer_id: null,
    notes: '',
    is_active: true,
    payables: {},
}

// quoteDates:每个金属最近一年的行情日期(数据量极小 —— 线上目前统共 3 个行情日)。
// 用来当场说出【选这个基准现在有没有区别】,而不是让人凭空以为均价在做平均。
export type QuoteDate = { metal: string; price_date: string }

export default function FormulaForm({
    substanceOptions,
    action,
    defaults,
    suppliers,
    customers,
    quoteDates,
    indices,
    locale,
}: {
    // PROC-4:物质清单由页面从 substances 那张字典读好传进来。
    // 【表单不再自己拿着一份清单】那份清单曾经是这份名单的第五个副本,
    // 而它与库里的顺序【实测已经对不上】(它按重要性,库里的视图按字母序)。
    substanceOptions: MetalOption[]
    action: (state: FormulaState, formData: FormData) => Promise<FormulaState>
    defaults: FormulaDefaults
    suppliers: PartyOption[]
    customers: PartyOption[]
    quoteDates: QuoteDate[]
    indices: MetalPriceIndex[]
    locale: string
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(action, initialState)

    // IDLE-DRAFT:草稿留存。受限与否由 lib/maskedTables.ts 推出来,
    // 不在这里声明 —— 见 lib/useFormDraft.ts 抬头。
    const formRef = useRef<HTMLFormElement>(null)
    const draft = useFormDraft({ formKey: 'pricing/formulas/form', table: 'pricing_formulas', subject: null, formRef })

    const [basis, setBasis] = useState(defaults.price_basis)
    const [mode, setMode] = useState<'generic' | 'supplier' | 'customer'>(
        defaults.supplier_id ? 'supplier' : defaults.customer_id ? 'customer' : 'generic'
    )
    const [averageDays, setAverageDays] = useState(defaults.average_days)
    // 【均价此刻在不在做平均】—— 这不是告警,是一句关于"引擎眼下到底在算什么"的事实。
    // 窗口里只有一条报价时,average 与 spot 得出的是同一个数,基准的选择是装饰性的。
    // 数出来的,不是断言的:窗口随上面填的天数变,行情覆盖变密了这句话自己就消失。
    const windowDays = Number(averageDays) > 0 ? Number(averageDays) : 30
    const cutoff = new Date(Date.now() - (windowDays - 1) * 86400000).toISOString().slice(0, 10)
    const perMetal = new Map<string, string[]>()
    for (const q of quoteDates) {
        if (q.price_date < cutoff) continue
        perMetal.set(q.metal, [...(perMetal.get(q.metal) ?? []), q.price_date])
    }
    const thin = [...perMetal.entries()].filter(([, d]) => d.length <= 1).map(([m]) => m)
    const latest = quoteDates.reduce<string | null>((a, q) => (a === null || q.price_date > a ? q.price_date : a), null)
    const allThin = perMetal.size > 0 && thin.length === perMetal.size

    const [treatment, setTreatment] = useState(defaults.treatment_charge_usd_per_tonne)
    const [discount, setDiscount] = useState(defaults.flat_discount_pct)
    const [payables, setPayables] = useState<Record<string, string>>(defaults.payables)

    const err = (k: string) => state.fieldErrors?.[k]

    return (
        <form ref={formRef} action={formAction} className="space-y-5 max-w-3xl">
                <DraftBanner draft={draft} />
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}

            <div className="flex flex-wrap gap-4">
                <div className="flex-1 min-w-[18rem]">
                    <label className="block text-sm font-medium mb-1">
                        {t('pricing.form.name')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="name"
                        required
                        defaultValue={defaults.name}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                    {err('name') && <p className="text-red-600 text-sm mt-1">{err('name')}</p>}
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">{t('pricing.form.direction')}</label>
                    <select
                        name="direction"
                        defaultValue={defaults.direction}
                        className="border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="both">{t('pricing.direction.both')}</option>
                        <option value="purchase">{t('pricing.direction.purchase')}</option>
                        <option value="sale">{t('pricing.direction.sale')}</option>
                    </select>
                </div>
            </div>

            {/* METAL-2:结算指数 —— 交易条款,与计价基准同级。
                合同挑指数(Doc 1:"LME or SMM"),而承诺时它会被抄进成交记录,
                此后改公式不再影响那一单(FIN-27)。
                【声明了指数,就看不见未标注指数的行情】—— 在那个指数的报价录进来
                之前,结算会点名拒绝,而不是拿一条不知出处的数字顶上。 */}
            <div className="mb-4">
                <label className="block text-sm font-medium mb-1">{t('pricing.form.priceIndex')}</label>
                <div className="max-w-xs">
                    <IndexPicker
                        name="price_index"
                        indices={indices}
                        defaultValue={defaults.price_index}
                        locale={locale}
                    />
                </div>
                <p className="text-xs text-gray-500 mt-1">{t('pricing.form.priceIndexHint')}</p>
            </div>

            {/* 计价基准:average 才出天数 */}
            <div className="flex flex-wrap items-end gap-4">
                <div>
                    <span className="block text-sm font-medium mb-1">{t('pricing.form.basis')}</span>
                    <label className="mr-4 text-sm">
                        <input
                            type="radio"
                            name="price_basis"
                            value="spot"
                            checked={basis === 'spot'}
                            onChange={() => setBasis('spot')}
                            className="mr-1"
                        />
                        {t('pricing.form.basisSpot')}
                    </label>
                    <label className="text-sm">
                        <input
                            type="radio"
                            name="price_basis"
                            value="average"
                            checked={basis === 'average'}
                            onChange={() => setBasis('average')}
                            className="mr-1"
                        />
                        {t('pricing.form.basisAverage')}
                    </label>
                </div>
                {basis === 'average' && (
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {t('pricing.form.averageDays')} <span className="text-red-600">*</span>
                        </label>
                        <DecimalInput
                            name="average_days"
                            value={averageDays}
                            onChange={setAverageDays}
                            className="w-24 border border-gray-300 px-3 py-2 rounded"
                        />
                        {err('average_days') && (
                            <p className="text-red-600 text-sm mt-1">{err('average_days')}</p>
                        )}
                    </div>
                )}
            </div>

            {/* 选基准的人应当当场看到:眼下这两个基准算出来是不是同一个数。
                线上实测(2026-08-10):七个金属的最新报价都是 7-30,30 天窗口里
                各只有一条 —— 于是 average 并没有在平均任何东西。这不是告警,
                是关于【计价引擎此刻到底做了多少事】的事实,所以摆在选择的旁边。 */}
            {allThin && latest && (
                <p className="text-sm bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded">
                    {t('pricing.form.basisSameToday', {
                        days: windowDays,
                        metals: thin.length,
                        date: latest,
                    })}
                </p>
            )}

            <div className="flex flex-wrap gap-4">
                <div>
                    <label className="block text-sm font-medium mb-1">{t('pricing.form.treatment')}</label>
                    <DecimalInput
                        name="treatment_charge_usd_per_tonne"
                        value={treatment}
                        onChange={setTreatment}
                        className="w-40 border border-gray-300 px-3 py-2 rounded"
                    />
                    {err('treatment_charge_usd_per_tonne') && (
                        <p className="text-red-600 text-sm mt-1">{err('treatment_charge_usd_per_tonne')}</p>
                    )}
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">{t('pricing.form.discount')}</label>
                    <DecimalInput
                        name="flat_discount_pct"
                        value={discount}
                        onChange={setDiscount}
                        className="w-32 border border-gray-300 px-3 py-2 rounded"
                    />
                    {err('flat_discount_pct') && (
                        <p className="text-red-600 text-sm mt-1">{err('flat_discount_pct')}</p>
                    )}
                </div>
            </div>

            {/* 适用对象 */}
            <div className="flex flex-wrap items-end gap-4">
                <div>
                    <span className="block text-sm font-medium mb-1">{t('pricing.form.counterpartyMode')}</span>
                    <input type="hidden" name="counterparty_mode" value={mode} />
                    <label className="mr-4 text-sm">
                        <input
                            type="radio"
                            checked={mode === 'generic'}
                            onChange={() => setMode('generic')}
                            className="mr-1"
                        />
                        {t('pricing.form.modeGeneric')}
                    </label>
                    <label className="mr-4 text-sm">
                        <input
                            type="radio"
                            checked={mode === 'supplier'}
                            onChange={() => setMode('supplier')}
                            className="mr-1"
                        />
                        {t('pricing.form.modeSupplier')}
                    </label>
                    <label className="text-sm">
                        <input
                            type="radio"
                            checked={mode === 'customer'}
                            onChange={() => setMode('customer')}
                            className="mr-1"
                        />
                        {t('pricing.form.modeCustomer')}
                    </label>
                </div>
                {mode === 'supplier' && (
                    <div className="flex-1 min-w-[16rem]">
                        {/* LOG-1b:空名单不画空下拉 —— 说出它是哪一种空(货代那一侧另有一句)。 */}
                        {suppliers.length === 0 ? (
                            <p className="text-sm text-amber-900 bg-amber-50 border border-amber-300 rounded px-3 py-2 max-w-xl">
                                {t('suppliers.pickerEmptyGoods')}
                            </p>
                        ) : (
                            <select
                                name="supplier_id"
                                defaultValue={defaults.supplier_id ?? ''}
                                className="w-full border border-gray-300 px-3 py-2 rounded"
                            >
                                <option value="">{t('finance.selectCounterparty')}</option>
                                {suppliers.map((s) => (
                                    <option key={s.id} value={s.id}>
                                        {s.name}
                                    </option>
                                ))}
                            </select>
                        )}
                        {err('supplier_id') && <p className="text-red-600 text-sm mt-1">{err('supplier_id')}</p>}
                    </div>
                )}
                {mode === 'customer' && (
                    <div className="flex-1 min-w-[16rem]">
                        <select
                            name="customer_id"
                            defaultValue={defaults.customer_id ?? ''}
                            className="w-full border border-gray-300 px-3 py-2 rounded"
                        >
                            <option value="">{t('finance.selectCounterparty')}</option>
                            {customers.map((c) => (
                                <option key={c.id} value={c.id}>
                                    {c.name}
                                </option>
                            ))}
                        </select>
                        {err('customer_id') && <p className="text-red-600 text-sm mt-1">{err('customer_id')}</p>}
                    </div>
                )}
            </div>

            <div className="flex flex-wrap gap-4">
                <label className="text-sm">
                    <input
                        type="checkbox"
                        name="is_active"
                        defaultChecked={defaults.is_active}
                        className="mr-2"
                    />
                    {t('pricing.form.active')}
                </label>
                <div className="flex-1 min-w-[16rem]">
                    <label className="block text-sm font-medium mb-1">{t('pricing.form.notes')}</label>
                    <input
                        type="text"
                        name="notes"
                        defaultValue={defaults.notes}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
            </div>

            {/* 计价比例 */}
            <div>
                <h2 className="text-lg font-semibold mb-1">{t('pricing.form.payableTitle')}</h2>
                <p className="text-sm text-gray-500 mb-3">{t('pricing.payableBlankHint')}</p>
                <table className="w-full border-collapse border border-gray-300 max-w-md">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('pricing.form.colMetal')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('pricing.form.colPayable')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {substanceOptions.filter((s) => s.isActive).map((opt) => (
                            <tr key={opt.value}>
                                <td className="border border-gray-300 px-4 py-2">
                                    {t(opt.labelKey)}
                                    <span className="text-gray-400 font-mono text-xs ml-2">{opt.value}</span>
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    <input type="hidden" name="payable_metal" value={opt.value} />
                                    <DecimalInput
                                        name="payable_pct"
                                        value={payables[opt.value] ?? ''}
                                        onChange={(raw) =>
                                            setPayables((p) => ({ ...p, [opt.value]: raw }))
                                        }
                                        className="w-28 border border-gray-300 px-3 py-2 rounded"
                                    />
                                    {err('payable_' + opt.value) && (
                                        <p className="text-red-600 text-sm mt-1">{err('payable_' + opt.value)}</p>
                                    )}
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            </div>

            <div className="flex gap-3 pt-2">
                <button
                    type="submit"
                    disabled={isPending}
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {isPending ? t('common.saving') : t('pricing.form.submit')}
                </button>
                <Link href="/pricing/formulas" className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50">
                    {t('common.cancel')}
                </Link>
            </div>
        </form>
    )
}
