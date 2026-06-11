'use client'

import { useRef, useState, useTransition } from 'react'
import Link from 'next/link'
import {
    commitProcessingRun,
    type CommitProcessingPayload,
} from './actions'
import { UNIT_OPTIONS } from '../../materials/options'

type InboundBatchOption = {
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
            setError('至少需要一条有效投入')
            return
        }

        const seen = new Set<string>()
        for (const inp of validInputs) {
            if (seen.has(inp.inbound_batch_id)) {
                setError('同一进料批次不能重复添加')
                return
            }
            seen.add(inp.inbound_batch_id)
        }

        for (const inp of validInputs) {
            const batch = inboundBatches.find((b) => b.id === inp.inbound_batch_id)
            if (batch && inp.quantity_consumed > batch.remaining_qty) {
                setError(`消耗数量超过剩余量: ${batch.code}`)
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
            setError('至少需要一条有效产出')
            return
        }

        const inSum = validInputs.reduce((s, r) => s + r.quantity_consumed, 0)
        const outSum = validOutputs.reduce((s, r) => s + r.quantity, 0)
        if (outSum > inSum) {
            setError('产出合计不能大于投入合计')
            return
        }

        let loss_qty: number | null = null
        if (lossOverride !== '') {
            const n = Number(lossOverride)
            if (Number.isNaN(n) || n < 0) {
                setError('损耗必须是不小于0的数字')
                return
            }
            loss_qty = n
        }

        const payload: CommitProcessingPayload = {
            process_date: processDate || null,
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
                    ← 返回列表
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-6">新增加工单</h1>

            {error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {error}
                </div>
            )}

            <form onSubmit={handleSubmit} className="space-y-4">
                {/* 加工日期 */}
                <div>
                    <label className="block text-sm font-medium mb-1">加工日期</label>
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
                        <h2 className="font-semibold">投入(消耗进料)</h2>
                        <button
                            type="button"
                            onClick={addInputRow}
                            className="text-blue-600 text-sm hover:underline"
                        >
                            + 添加投入
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
                                            请选择进料批次
                                        </option>
                                        {inboundBatches.map((b) => (
                                            <option key={b.id} value={b.id}>
                                                {b.code} - {b.materials?.name ?? '—'}(剩余 {b.remaining_qty} {b.unit})
                                            </option>
                                        ))}
                                    </select>
                                    <input
                                        type="number"
                                        step="any"
                                        min="0"
                                        placeholder="消耗数量"
                                        value={row.quantity_consumed}
                                        onChange={(e) =>
                                            updateInputRow(row.key, {
                                                quantity_consumed: e.target.value,
                                            })
                                        }
                                        className="w-32 border border-gray-300 px-3 py-2 rounded"
                                    />
                                    <button
                                        type="button"
                                        onClick={() => removeInputRow(row.key)}
                                        className="text-red-600 text-sm hover:underline py-2"
                                    >
                                        删除
                                    </button>
                                </div>
                                {exceeds && (
                                    <p className="text-red-600 text-xs mt-1 ml-1">超过剩余量</p>
                                )}
                            </div>
                        )
                    })}
                    {inboundBatches.length === 0 && (
                        <p className="text-xs text-amber-600">
                            没有可加工的进料批次(剩余量&gt;0),请先{' '}
                            <Link href="/inbound/new" className="underline">
                                创建进料
                            </Link>
                        </p>
                    )}
                </section>

                {/* 产出 */}
                <section className="border border-gray-200 rounded p-4 space-y-3">
                    <div className="flex items-center justify-between">
                        <h2 className="font-semibold">产出(生成成品)</h2>
                        <button
                            type="button"
                            onClick={addOutputRow}
                            className="text-blue-600 text-sm hover:underline"
                        >
                            + 添加产出
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
                                    请选择产出物料
                                </option>
                                {materials.map((m) => (
                                    <option key={m.id} value={m.id}>
                                        {m.code} - {m.name}
                                    </option>
                                ))}
                            </select>
                            <input
                                type="number"
                                step="any"
                                min="0"
                                placeholder="数量"
                                value={row.quantity}
                                onChange={(e) =>
                                    updateOutputRow(row.key, { quantity: e.target.value })
                                }
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
                                    <option key={u} value={u}>
                                        {u}
                                    </option>
                                ))}
                            </select>
                            <input
                                type="text"
                                placeholder="品位/纯度"
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
                                删除
                            </button>
                        </div>
                    ))}
                </section>

                {/* 合计 + 损耗 */}
                <div className="bg-gray-50 rounded p-4 space-y-2">
                    <div className="flex items-center gap-6 flex-wrap">
                        <div>
                            <span className="text-sm text-gray-600 mr-1">投入合计:</span>
                            <span className="font-medium">{totalInput}</span>
                        </div>
                        <div>
                            <span className="text-sm text-gray-600 mr-1">产出合计:</span>
                            <span className="font-medium">{totalOutput}</span>
                        </div>
                        <div className="flex items-center gap-2">
                            <span className="text-sm text-gray-600">损耗:</span>
                            <input
                                type="number"
                                step="any"
                                value={displayLoss}
                                onChange={(e) => setLossOverride(e.target.value)}
                                className="w-28 border border-gray-300 px-2 py-1 rounded text-sm"
                            />
                            {lossOverride !== '' && (
                                <button
                                    type="button"
                                    onClick={() => setLossOverride('')}
                                    className="text-xs text-blue-600 hover:underline"
                                >
                                    重置为自动
                                </button>
                            )}
                        </div>
                    </div>
                    {autoLoss < 0 && (
                        <p className="text-red-600 text-xs">产出大于投入,请检查数量</p>
                    )}
                </div>

                {/* 备注 */}
                <div>
                    <label className="block text-sm font-medium mb-1">备注</label>
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
                        {isPending ? '保存中...' : '保存加工单'}
                    </button>
                    <Link
                        href="/processing"
                        className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                    >
                        取消
                    </Link>
                </div>
            </form>
        </div>
    )
}
