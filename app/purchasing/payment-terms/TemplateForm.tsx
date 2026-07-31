'use client'

// 付款条款模板表单(新建/编辑共用):名称/说明/启用 + 动态期次表。
// 每行:期次标签、模式单选(比例 | 定额)+ 对应输入、触发事件;fixed_date 另出
// 偏移天数(模板不可能知道具体日期,存"下单日 + N 天",套用时换算)。
// 比例合计实时显示:<100 只提示(余下部分不列入计划是合法的 —— 尾款常常"按化验实算"),
// >100 拦下不让交。行序即期次,提交时按行序重排 seq。
import { useActionState, useState } from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import DecimalInput from '@/app/components/forms/DecimalInput'
import { saveTemplate, type TemplateFormState, type TemplateLineInput } from './actions'

const initialState: TemplateFormState = {}

export const TRIGGER_OPTIONS = ['on_order', 'on_shipment', 'on_arrival', 'post_assay', 'fixed_date'] as const

export function emptyTermLine(): TemplateLineInput {
    return { label: '', mode: 'percentage', percentage: '', fixed_amount: '', trigger_event: 'on_order', days_offset: '' }
}

export default function TemplateForm({
    template,
}: {
    template?: {
        id: string
        name: string
        description: string | null
        is_active: boolean
        lines: TemplateLineInput[]
    }
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(saveTemplate, initialState)

    const [lines, setLines] = useState<TemplateLineInput[]>(
        template?.lines.length ? template.lines : [emptyTermLine()]
    )

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
                                    {TRIGGER_OPTIONS.map((ev) => (
                                        <option key={ev} value={ev}>
                                            {t('purchasing.trigger.' + ev)}
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
                                <button
                                    type="button"
                                    onClick={() => removeLine(i)}
                                    disabled={lines.length === 1}
                                    className="text-red-600 hover:underline text-sm disabled:text-gray-300 disabled:no-underline"
                                >
                                    {t('purchasing.form.removeLine')}
                                </button>
                            </td>
                        </tr>
                    ))}
                </tbody>
            </table>
            <div className="flex items-center justify-between">
                <button
                    type="button"
                    onClick={() => setLines((ls) => [...ls, emptyTermLine()])}
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('purchasing.form.addTerm')}
                </button>
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
                <button
                    type="submit"
                    disabled={isPending || pctOver}
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {isPending ? t('common.saving') : t('common.save')}
                </button>
                <Link
                    href="/purchasing/payment-terms"
                    className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                >
                    {t('common.cancel')}
                </Link>
            </div>
        </form>
    )
}
