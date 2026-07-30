'use client'

import { useRef, useState, useTransition } from 'react'
import Link from 'next/link'
import {
    commitProcessingRun,
    type CommitProcessingPayload,
} from './actions'
import { UNIT_OPTIONS } from '../../materials/options'
import { useTranslations } from '@/lib/i18n/client'
import DecimalInput from '../../components/forms/DecimalInput'

export type InboundBatchOption = {
    id: string
    code: string
    remaining_qty: number
    unit: string
    materials: { name: string } | null
}

type MaterialOption = {
    id: string
    code: string
    name: string
}

type InputRowState = {
    key: number
    inbound_batch_id: string
    quantity_consumed: string
}

type OutputRowState = {
    key: number
    material_id: string
    quantity: string
    unit: string
    purity: string
}

function todayIsoLocal(): string {
    const d = new Date()
    const yyyy = d.getFullYear()
    const mm = String(d.getMonth() + 1).padStart(2, '0')
    const dd = String(d.getDate()).padStart(2, '0')
    return `${yyyy}-${mm}-${dd}`
}

export default function NewProcessingForm({
    inboundBatches,
    materials,
}: {
    inboundBatches: InboundBatchOption[]
    materials: MaterialOption[]
}) {
    const t = useTranslations()
    const keyCounter = useRef(0)
    const nextKey = () => keyCounter.current++

    const [inputRows, setInputRows] = useState<InputRowState[]>(() => [
        { key: nextKey(), inbound_batch_id: '', quantity_consumed: '' },
    ])
    const [outputRows, setOutputRows] = useState<OutputRowState[]>(() => [
        { key: nextKey(), material_id: '', quantity: '', unit: 'kg', purity: '' },
    ])
    const [processDate, setProcessDate] = useState(todayIsoLocal)
    const [notes, setNotes] = useState('')
    const [lossOverride, setLossOverride] = useState('')
    const [error, setError] = useState<string | null>(null)
    const [isPending, startTransition] = useTransition()

    // 派生值(每次渲染重算)
    const totalInput = inputRows.reduce((sum, r) => {
        const n = Number(r.quantity_consumed)
        return Number.isNaN(n) || n <= 0 ? sum : sum + n
    }, 0)
    const totalOutput = outputRows.reduce((sum, r) => {
        const n = Number(r.quantity)
        return Number.isNaN(n) || n <= 0 ? sum : sum + n
    }, 0)
    const autoLoss = totalInput - totalOutput
    const displayLoss = lossOverride !== '' ? lossOverride : String(autoLoss)

    // 投入行操作
    function updateInputRow(key: number, patch: Partial<InputRowState>) {
        setInputRows((rows) =>
            rows.map((r) => (r.key === key ? { ...r, ...patch } : r))
        )
    }
    function addInputRow() {
        setInputRows((rows) => [
            ...rows,
            { key: nextKey(), inbound_batch_id: '', quantity_consumed: '' },
        ])
    }
    function removeInputRow(key: number) {
        setInputRows((rows) => {
            // 至少保留一行;最后一行就地清空
            if (rows.length === 1) {
                return [{ key: rows[0].key, inbound_batch_id: '', quantity_consumed: '' }]
            }
            return rows.filter((r) => r.key !== key)
        })
    }

    // 产出行操作
    function updateOutputRow(key: number, patch: Partial<OutputRowState>) {
        setOutputRows((rows) =>
            rows.map((r) => (r.key === key ? { ...r, ...patch } : r))
        )
    }
    function addOutputRow() {
        setOutputRows((rows) => [
            ...rows,
            { key: nextKey(), material_id: '', quantity: '', unit: 'kg', purity: '' },
        ])
    }
    function removeOutputRow(key: number) {
        setOutputRows((rows) => {
            if (rows.length === 1) {
                return [
                    { key: rows[0].key, material_id: '', quantity: '', unit: 'kg', purity: '' },
                ]
            }
            return rows.filter((r) => r.key !== key)
        })
    }

    function handleSubmit(e: React.FormEvent) {
        e.preventDefault()
        setError(null)

        const validInputs = inputRows
            .filter((r) => r.inbound_batch_id && Number(r.quantity_consumed) > 0)
            .map((r) => ({
                inbound_batch_id: r.inbound_batch_id,
                quantity_consumed: Number(r.quantity_consumed),
            }))

        if (validInputs.length === 0) {
            setError(t('processing.validation.needValidInput'))
            return
        }

        const seen = new Set<string>()
        for (const inp of validInputs) {
            if (seen.has(inp.inbound_batch_id)) {
                setError(t('processing.validation.duplicateInputClient'))
                return
            }
            seen.add(inp.inbound_batch_id)
        }

        for (const inp of validInputs) {
            const batch = inboundBatches.find((b) => b.id === inp.inbound_batch_id)
            if (batch && inp.quantity_consumed > batch.remaining_qty) {
                setError(t('processing.validation.consumeExceedsClient', { code: batch.code }))
                return
            }
        }

        const validOutputs = outputRows
            .filter((r) => r.material_id && Number(r.quantity) > 0)
            .map((r) => ({
                material_id: r.material_id,
                quantity: Number(r.quantity),
                unit: r.unit,
                purity: r.purity.trim() || null,
            }))

        if (validOutputs.length === 0) {
            setError(t('processing.validation.needValidOutput'))
            return
        }

        const inSum = validInputs.reduce((s, r) => s + r.quantity_consumed, 0)
        const outSum = validOutputs.reduce((s, r) => s + r.quantity, 0)
        if (outSum > inSum) {
            setError(t('processing.validation.outputExceedsInputClient'))
            return
        }

        let loss_qty: number | null = null
        if (lossOverride !== '') {
            const n = Number(lossOverride)
            if (Number.isNaN(n) || n < 0) {
                setError(t('processing.validation.lossInvalidClient'))
                return
            }
            loss_qty = n
        }

        const payload: CommitProcessingPayload = {
            process_date: processDate,
            notes: notes.trim() || null,
            loss_qty,
            inputs: validInputs,
            outputs: validOutputs,
        }

        startTransition(async () => {
            const result = await commitProcessingRun(payload)
            if (result?.error) setError(result.error)
            // 成功:服务端 redirect 接管
        })
    }

    return (
        <div className="p-8 max-w-3xl">
            <div className="mb-6">
                <Link
                    href="/processing"
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-6">{t('processing.newTitle')}</h1>

            {error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {error}
                </div>
            )}

            <form onSubmit={handleSubmit} className="space-y-4">
                {/* 加工日期 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('processing.form.dateLabel')}</label>
                    <input
                        type="date"
                        value={processDate}
                        onChange={(e) => setProcessDate(e.target.value)}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                {/* 投入 */}
                <section className="border border-gray-200 rounded p-4 space-y-3">
                    <div className="flex items-center justify-between">
                        <h2 className="font-semibold">{t('processing.form.inputsSectionHeader')}</h2>
                        <button
                            type="button"
                            onClick={addInputRow}
                            className="text-blue-600 text-sm hover:underline"
                        >
                            {t('processing.form.addInputButton')}
                        </button>
                    </div>
                    {inputRows.map((row) => {
                        const selectedBatch = inboundBatches.find(
                            (b) => b.id === row.inbound_batch_id
                        )
                        const qtyNum = Number(row.quantity_consumed)
                        const exceeds =
                            selectedBatch &&
                            !Number.isNaN(qtyNum) &&
                            qtyNum > selectedBatch.remaining_qty
                        return (
                            <div key={row.key}>
                                <div className="flex gap-2 items-start">
                                    <select
                                        value={row.inbound_batch_id}
                                        onChange={(e) =>
                                            updateInputRow(row.key, {
                                                inbound_batch_id: e.target.value,
                                            })
                                        }
                                        className="flex-1 border border-gray-300 px-3 py-2 rounded"
                                    >
                                        <option value="" disabled>
                                            {t('processing.form.selectInboundBatch')}
                                        </option>
                                        {inboundBatches.map((b) => (
                                            <option key={b.id} value={b.id}>
                                                {t('processing.form.inboundOptionLabel', {
                                                    code: b.code,
                                                    name: b.materials?.name ?? '—',
                                                    remaining: b.remaining_qty,
                                                    unit: b.unit,
                                                })}
                                            </option>
                                        ))}
                                    </select>
                                    <DecimalInput
                                        placeholder={t('processing.form.consumeQtyPlaceholder')}
                                        value={row.quantity_consumed}
                                        onChange={(raw) =>
                                            updateInputRow(row.key, {
                                                quantity_consumed: raw,
                                            })
                                        }
                                        className="w-32 border border-gray-300 px-3 py-2 rounded"
                                    />
                                    <button
                                        type="button"
                                        onClick={() => removeInputRow(row.key)}
                                        className="text-red-600 text-sm hover:underline py-2"
                                    >
                                        {t('processing.form.rowDelete')}
                                    </button>
                                </div>
                                {exceeds && (
                                    <p className="text-red-600 text-xs mt-1 ml-1">{t('processing.form.rowExceeds')}</p>
                                )}
                            </div>
                        )
                    })}
                    {inboundBatches.length === 0 && (
                        <p className="text-xs text-amber-600">
                            {t('processing.form.noInboundHelper')}
                            <Link href="/inbound/new" className="underline">
                                {t('processing.form.noInboundLink')}
                            </Link>
                            {t('processing.form.noInboundHelperPost')}
                        </p>
                    )}
                </section>

                {/* 产出 */}
                <section className="border border-gray-200 rounded p-4 space-y-3">
                    <div className="flex items-center justify-between">
                        <h2 className="font-semibold">{t('processing.form.outputsSectionHeader')}</h2>
                        <button
                            type="button"
                            onClick={addOutputRow}
                            className="text-blue-600 text-sm hover:underline"
                        >
                            {t('processing.form.addOutputButton')}
                        </button>
                    </div>
                    {outputRows.map((row) => (
                        <div key={row.key} className="flex gap-2 items-start">
                            <select
                                value={row.material_id}
                                onChange={(e) =>
                                    updateOutputRow(row.key, { material_id: e.target.value })
                                }
                                className="flex-1 border border-gray-300 px-3 py-2 rounded"
                            >
                                <option value="" disabled>
                                    {t('processing.form.selectOutputMaterial')}
                                </option>
                                {materials.map((m) => (
                                    <option key={m.id} value={m.id}>
                                        {m.code} - {m.name}
                                    </option>
                                ))}
                            </select>
                            <DecimalInput
                                placeholder={t('processing.form.outputQtyPlaceholder')}
                                value={row.quantity}
                                onChange={(raw) => updateOutputRow(row.key, { quantity: raw })}
                                className="w-28 border border-gray-300 px-3 py-2 rounded"
                            />
                            <select
                                value={row.unit}
                                onChange={(e) =>
                                    updateOutputRow(row.key, { unit: e.target.value })
                                }
                                className="w-24 border border-gray-300 px-3 py-2 rounded"
                            >
                                {UNIT_OPTIONS.map((u) => (
                                    <option key={u.value} value={u.value}>
                                        {t(u.labelKey)}
                                    </option>
                                ))}
                            </select>
                            <input
                                type="text"
                                placeholder={t('processing.form.purityPlaceholder')}
                                value={row.purity}
                                onChange={(e) =>
                                    updateOutputRow(row.key, { purity: e.target.value })
                                }
                                className="w-36 border border-gray-300 px-3 py-2 rounded"
                            />
                            <button
                                type="button"
                                onClick={() => removeOutputRow(row.key)}
                                className="text-red-600 text-sm hover:underline py-2"
                            >
                                {t('processing.form.rowDelete')}
                            </button>
                        </div>
                    ))}
                </section>

                {/* 合计 + 损耗 */}
                <div className="bg-gray-50 rounded p-4 space-y-2">
                    <div className="flex items-center gap-6 flex-wrap">
                        <div>
                            <span className="text-sm text-gray-600 mr-1">{t('processing.form.totalInputLabel')}</span>
                            <span className="font-medium">{totalInput}</span>
                        </div>
                        <div>
                            <span className="text-sm text-gray-600 mr-1">{t('processing.form.totalOutputLabel')}</span>
                            <span className="font-medium">{totalOutput}</span>
                        </div>
                        <div className="flex items-center gap-2">
                            <span className="text-sm text-gray-600">{t('processing.form.lossLabel')}</span>
                            {/* 自动损耗可能为负(产出大于投入),显示的就是它 ——
                                故允许负号,否则用户没法编辑一个负值;
                                负数的手工覆盖仍由提交前的 lossInvalidClient 拦下 */}
                            <DecimalInput
                                allowNegative
                                value={displayLoss}
                                onChange={setLossOverride}
                                className="w-28 border border-gray-300 px-2 py-1 rounded text-sm"
                            />
                            {lossOverride !== '' && (
                                <button
                                    type="button"
                                    onClick={() => setLossOverride('')}
                                    className="text-xs text-blue-600 hover:underline"
                                >
                                    {t('processing.form.resetToAuto')}
                                </button>
                            )}
                        </div>
                    </div>
                    {autoLoss < 0 && (
                        <p className="text-red-600 text-xs">{t('processing.form.outputExceedsWarning')}</p>
                    )}
                </div>

                {/* 备注 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('processing.form.notesLabel')}</label>
                    <textarea
                        value={notes}
                        onChange={(e) => setNotes(e.target.value)}
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
                        {isPending ? t('processing.form.saving') : t('processing.form.saveRun')}
                    </button>
                    <Link
                        href="/processing"
                        className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                    >
                        {t('common.cancel')}
                    </Link>
                </div>
            </form>
        </div>
    )
}
