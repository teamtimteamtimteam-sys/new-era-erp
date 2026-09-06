'use client'

// 付款条款模板表单(新建/编辑共用):名称/说明/启用 + 动态期次表。
// 每行:期次标签、模式单选(比例 | 定额)+ 对应输入、触发事件;fixed_date 另出
// 偏移天数(模板不可能知道具体日期,存"下单日 + N 天",套用时换算)。
// 比例合计实时显示:<100 只提示(余下部分不列入计划是合法的 —— 尾款常常"按化验实算"),
// >100 拦下不让交。行序即期次,提交时按行序重排 seq。
import { useActionState, useState } from 'react'
import Link from 'next/link'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { triggerLabel, type PaymentTriggerEvent } from '@/lib/paymentTriggers'
import DecimalInput from '@/app/components/forms/DecimalInput'
import { saveTemplate, type TemplateFormState, type TemplateLineInput } from './actions'
import { Button } from '@/app/components/ui/button'

const initialState: TemplateFormState = {}

// EQP-PAY-1:那个硬编码的数组退役了 —— 里程碑的真源是 payment_trigger_events。
//
// ★【模板【不】按种类过滤,这是刻意的】★ 一份模板【不属于任何一张采购单】
// (它的抬头就是这么写的:"存在的唯一理由是省去重复录入"),所以它没有种类可言。
// 判据落在【套用的那一刻】:apply_payment_term_template 往
// purchase_order_payment_terms 里插行,而那张表上的 guard_payment_term_applicable
// 会按目标单据的种类按名拒。把一个用不上的组合拦在套用处,而不是拦在模板处,
// 是因为同一份模板可能对材料单成立、对设备单不成立 —— 那不是模板的错。

export function emptyTermLine(): TemplateLineInput {
    return { label: '', mode: 'percentage', percentage: '', fixed_amount: '', trigger_event: 'on_order', days_offset: '' }
}

export default function TemplateForm({
    template,
    currencies,
    triggerEvents,
}: {
    template?: {
        id: string
        name: string
        description: string | null
        is_active: boolean
        currency: string | null
        lines: TemplateLineInput[]
    }
    currencies: { code: string }[]
    // EQP-PAY-1:整份字典(模板不按种类过滤 —— 理由见文件顶部)。
    triggerEvents: PaymentTriggerEvent[]
}) {
    const t = useTranslations()
    const locale = useLocale()
    const [state, formAction, isPending] = useActionState(saveTemplate, initialState)

    const [lines, setLines] = useState<TemplateLineInput[]>(
        template?.lines.length ? template.lines : [emptyTermLine()]
    )
    const [currency, setCurrency] = useState<string>(template?.currency ?? '')

    // FIN-29:定额腿才需要币种。没有定额腿时整个字段收起来 —— 摆一个用不上的
    // 必填框,人只会随便选一个,而随便选的字段迟早被当真。
    const hasFixed = lines.some((l) => l.mode === 'fixed')

    function patchLine(i: number, patch: Partial<TemplateLineInput>) {
        setLines((ls) => ls.map((l, j) => (j === i ? { ...l, ...patch } : l)))
    }
    function removeLine(i: number) {
        setLines((ls) => (ls.length > 1 ? ls.filter((_, j) => j !== i) : ls))
    }

    const pctTotal = Math.round(
        lines.reduce((s, l) => {
            if (l.mode !== 'percentage') return s
            const n = Number(l.percentage)
            return s + (l.percentage && !Number.isNaN(n) ? n : 0)
        }, 0) * 100
    ) / 100
    const pctOver = pctTotal > 100

    return (
        <form action={formAction} className="space-y-4 max-w-3xl">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}

            {template && <input type="hidden" name="template_id" value={template.id} />}
            <input type="hidden" name="lines_json" value={JSON.stringify(lines)} />

            <div className="flex flex-wrap gap-4">
                <div className="flex-1 min-w-[16rem]">
                    <label className="block text-sm font-medium mb-1">
                        {t('purchasing.colName')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="name"
                        required
                        defaultValue={template?.name ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                <div className="flex-1 min-w-[16rem]">
                    <label className="block text-sm font-medium mb-1">{t('purchasing.colDescription')}</label>
                    <input
                        type="text"
                        name="description"
                        defaultValue={template?.description ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                <label className="flex items-end gap-2 pb-2 text-sm">
                    <input
                        type="checkbox"
                        name="is_active"
                        defaultChecked={template?.is_active ?? true}
                    />
                    {t('pricing.form.active')}
                </label>
            </div>

            {/* FIN-29:定额腿的币种。模板不属于任何单据,所以定额在被套到某张 PO 上
                之前没有币种可言 —— 声明它,套用时币种不同即拒(不换算:付款条款是
                谈定的承诺,不是算出来的量)。只有比例的模板不需要,字段就不出现。 */}
            {hasFixed && (
                <div className="max-w-xs">
                    <label className="block text-sm font-medium mb-1">
                        {t('purchasing.form.templateCurrency')} <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="currency"
                        value={currency}
                        onChange={(e) => setCurrency(e.target.value)}
                        required
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="">—</option>
                        {currencies.map((c) => (
                            <option key={c.code} value={c.code}>{c.code}</option>
                        ))}
                    </select>
                    <p className="text-xs text-gray-500 mt-1">{t('purchasing.form.templateCurrencyHint')}</p>
                </div>
            )}
            {!hasFixed && <input type="hidden" name="currency" value="" />}

            <h2 className="font-bold pt-2">{t('purchasing.form.paymentTerms')}</h2>
            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-3 py-2 text-left w-10">{t('purchasing.colSeq')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('purchasing.colLabel')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('purchasing.colShare')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('purchasing.colTrigger')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left w-16" />
                    </tr>
                </thead>
                <tbody>
                    {lines.map((l, i) => (
                        <tr key={i}>
                            <td className="border border-gray-300 px-3 py-2 text-sm text-gray-500">{i + 1}</td>
                            <td className="border border-gray-300 px-3 py-2">
                                <input
                                    type="text"
                                    value={l.label}
                                    onChange={(e) => patchLine(i, { label: e.target.value })}
                                    className="w-full border border-gray-300 px-2 py-1 rounded"
                                />
                            </td>
                            <td className="border border-gray-300 px-3 py-2">
                                <div className="flex items-center gap-2">
                                    <label className="flex items-center gap-1 text-sm">
                                        <input
                                            type="radio"
                                            checked={l.mode === 'percentage'}
                                            onChange={() => patchLine(i, { mode: 'percentage' })}
                                        />
                                        {t('purchasing.form.modePct')}
                                    </label>
                                    <label className="flex items-center gap-1 text-sm">
                                        <input
                                            type="radio"
                                            checked={l.mode === 'fixed'}
                                            onChange={() => patchLine(i, { mode: 'fixed' })}
                                        />
                                        {t('purchasing.form.modeFixed')}
                                    </label>
                                    {l.mode === 'percentage' ? (
                                        <DecimalInput
                                            value={l.percentage}
                                            onChange={(v) => patchLine(i, { percentage: v })}
                                            placeholder={t('purchasing.form.percentage')}
                                            className="w-24 border border-gray-300 px-2 py-1 rounded"
                                        />
                                    ) : (
                                        <DecimalInput
                                            value={l.fixed_amount}
                                            onChange={(v) => patchLine(i, { fixed_amount: v })}
                                            placeholder={t('purchasing.form.fixedAmount')}
                                            className="w-28 border border-gray-300 px-2 py-1 rounded"
                                        />
                                    )}
                                </div>
                            </td>
                            <td className="border border-gray-300 px-3 py-2">
                                <select
                                    value={l.trigger_event}
                                    onChange={(e) => patchLine(i, { trigger_event: e.target.value })}
                                    className="border border-gray-300 px-2 py-1 rounded"
                                >
                                    {triggerEvents.map((ev) => (
                                        <option key={ev.code} value={ev.code}>
                                            {triggerLabel(ev, locale)}
                                        </option>
                                    ))}
                                </select>
                                {l.trigger_event === 'fixed_date' && (
                                    <span className="ml-2 inline-flex items-center gap-1">
                                        <DecimalInput
                                            value={l.days_offset}
                                            onChange={(v) => patchLine(i, { days_offset: v })}
                                            className="w-16 border border-gray-300 px-2 py-1 rounded"
                                        />
                                        <span className="text-xs text-gray-500">{t('purchasing.daysOffsetHint')}</span>
                                    </span>
                                )}
                            </td>
                            <td className="border border-gray-300 px-3 py-2">
                                <Button
                                    variant="secondary"
                                    size="inline"
                                    type="button"
                                    onClick={() => removeLine(i)}
                                    disabled={lines.length === 1}
                                    className="text-sm"
                                >
                                    {t('purchasing.form.removeLine')}
                                </Button>
                            </td>
                        </tr>
                    ))}
                </tbody>
            </table>
            <div className="flex items-center justify-between">
                <Button
                    variant="link"
                    size="inline"
                    type="button"
                    onClick={() => setLines((ls) => [...ls, emptyTermLine()])}
                >
                    {t('purchasing.form.addTerm')}
                </Button>
                {/* 比例合计:>100 拦下;<100 只是提醒(尾款按实算是常态) */}
                {pctOver ? (
                    <p className="text-sm text-red-600">
                        {t('purchasing.errors.TERMS_PCT_EXCEEDS', { 0: pctTotal })}
                    </p>
                ) : pctTotal > 0 && pctTotal < 100 ? (
                    <p className="text-sm text-amber-700">{t('purchasing.pctUnder', { total: pctTotal })}</p>
                ) : pctTotal === 100 ? (
                    <p className="text-sm text-gray-500 font-mono">100%</p>
                ) : null}
            </div>

            <div className="flex gap-3 pt-2">
                <Button
                    type="submit"
                    disabled={isPending || pctOver}
                >
                    {isPending ? t('common.saving') : t('common.save')}
                </Button>
                <Button asChild variant="secondary">
                    <Link
                        href="/purchasing/payment-terms"
                    >
                        {t('common.cancel')}
                    </Link>
                </Button>
            </div>
        </form>
    )
}
