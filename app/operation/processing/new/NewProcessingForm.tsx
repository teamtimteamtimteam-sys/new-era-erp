'use client'

import { useRef, useState, useTransition } from 'react'
import Link from 'next/link'
import {
    commitProcessingRun,
    type CommitProcessingPayload,
} from './actions'
import { UNIT_OPTIONS } from '../../../materials/options'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import DecimalInput from '../../../components/forms/DecimalInput'
import { Button } from '@/app/components/ui/button'

export type InboundBatchOption = {
    id: string
    code: string
    remaining_qty: number
    // IOD-1:可投的是可用,不是物理剩余(被扣住的货不可动用)
    available_qty: number
    unit: string
    materials: { name: string } | null
}

// FIN-25:再加工 —— 可投料的产出批(同形;value 前缀区分来源)
export type OutputBatchOption = InboundBatchOption

// PROC-WIRE-1B-i:一道工序,连同它【收什么形态】与【产不产批】。
export type OperationOption = {
    code: string
    name_en: string
    name_zh: string
    produces_outputs: boolean
    input_forms: { code: string; name_en: string; name_zh: string }[]
}

type MaterialOption = {
    id: string
    code: string
    name: string
}

type InputRowState = {
    key: number
    // FIN-25:'in:<id>'(进料批)或 'out:<id>'(产出批再加工)
    batch_ref: string
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
    outputBatches,
    materials,
    defaultAllocationBasis,
    workOrders,
    operations,
}: {
    inboundBatches: InboundBatchOption[]
    outputBatches: OutputBatchOption[]
    materials: MaterialOption[]
    /** 预选值,来自 finance_settings.default_allocation_basis(FIN-36)*/
    defaultAllocationBasis: string
    /** WO-1c:【只有已放行的】—— 服务端也拒(WO_NOT_RELEASED),这里不画必然被拒的选项 */
    workOrders: { id: string; code: string; scheduled_date: string | null }[]
    /** PROC-WIRE-1B-i:五道工序(R2),带它收什么形态、产不产批。
     *  **accepts / produces 都是从字典读来的**,不是在这里写死的 —— 加一道工序
     *  或者改它收什么,是加一行数据,这一屏不必改。 */
    operations: OperationOption[]
}) {
    const t = useTranslations()
    const locale = useLocale()
    // FIN-36:成本分摊基准是【选出来的】。预选自公司配置,但屏幕上看得见、改得动 ——
    // 与它取代的那个 schema 默认值的区别全在这里。选中的值会显式送给
    // commit_processing_run(那边必填),所以"这一单用了什么方法"是记录,不是推断。
    const [allocationBasis, setAllocationBasis] = useState(defaultAllocationBasis)
    // WO-1c:照哪张工单做的。【默认不选】—— 临时起意的加工是合法的,而
    // 预选一张工单等于替人做了一个"这次是照计划做的"的判断。
    const [workOrderId, setWorkOrderId] = useState('')
    // PROC-WIRE-1B-i:【默认不选】—— 预选一道工序等于替人断言这一炉在跑哪台机器。
    const [operationCode, setOperationCode] = useState('')
    const operation = operations.find((o) => o.code === operationCode) ?? null
    // 【产不产批由字典说了算】不是"是不是深度放电"这种写死的判断。
    const producesOutputs = operation ? operation.produces_outputs : true
    const keyCounter = useRef(0)
    const nextKey = () => keyCounter.current++

    const [inputRows, setInputRows] = useState<InputRowState[]>(() => [
        { key: nextKey(), batch_ref: '', quantity_consumed: '' },
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
            { key: nextKey(), batch_ref: '', quantity_consumed: '' },
        ])
    }
    function removeInputRow(key: number) {
        setInputRows((rows) => {
            // 至少保留一行;最后一行就地清空
            if (rows.length === 1) {
                return [{ key: rows[0].key, batch_ref: '', quantity_consumed: '' }]
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

        const validRows = inputRows.filter((r) => r.batch_ref && Number(r.quantity_consumed) > 0)
        const validInputs = validRows.map((r) => ({
            ...(r.batch_ref.startsWith('out:')
                ? { output_batch_id: r.batch_ref.slice(4) }
                : { inbound_batch_id: r.batch_ref.slice(3) }),
            quantity_consumed: Number(r.quantity_consumed),
        }))

        if (validInputs.length === 0) {
            setError(t('processing.validation.needValidInput'))
            return
        }

        const seen = new Set<string>()
        for (const r of validRows) {
            if (seen.has(r.batch_ref)) {
                setError(t('processing.validation.duplicateInputClient'))
                return
            }
            seen.add(r.batch_ref)
        }

        for (const r of validRows) {
            const pool = r.batch_ref.startsWith('out:') ? outputBatches : inboundBatches
            const batch = pool.find((b) => b.id === r.batch_ref.slice(r.batch_ref.indexOf(':') + 1))
            if (batch && Number(r.quantity_consumed) > batch.available_qty) {
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
            allocation_basis: allocationBasis,
            work_order_id: workOrderId || null,
            operation_type_code: operationCode || null,
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
                    href="/operation/processing"
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
                {/* 成本分摊基准(FIN-36)—— 预选自公司配置,但【必须看得见、改得动】。
                    它直接决定每个产出批次的报告毛利:同一张单按重量与按金属价值分摊,
                    单位成本可以差出一倍以上(FIN-25 量过 62.50 对 27.50)。 */}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('processing.form.basisLabel')}
                    </label>
                    <select
                        value={allocationBasis}
                        onChange={(e) => setAllocationBasis(e.target.value)}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="metal_value">{t('processing.allocation.basis.metal_value')}</option>
                        <option value="weight">{t('processing.allocation.basis.weight')}</option>
                    </select>
                    <p className="text-xs text-gray-500 mt-1">{t('processing.form.basisHint')}</p>
                </div>

                {/* WO-1c:照哪一张工单做的 —— 【可选】。
                    【为什么不从计划里预填投料】计划写的是【物料】(排计划时批次往往
                    还不存在),而这里填的是【批次】。系统挑一个批次填进去,会是一个
                    看起来很合理、而车间当天未必是这么投的答案 —— 一个似是而非的
                    错答案比留空坏得多(与 restricted-is-not-zero 同一条)。
                    挑批次是开工那天的决定,这里只问"这次算在哪张计划上"。 */}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('processing.form.workOrderLabel')}
                    </label>
                    <select
                        value={workOrderId}
                        onChange={(e) => setWorkOrderId(e.target.value)}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="">{t('processing.form.workOrderNone')}</option>
                        {workOrders.map((w) => (
                            <option key={w.id} value={w.id}>
                                {w.code}{w.scheduled_date ? ` — ${w.scheduled_date}` : ''}
                            </option>
                        ))}
                    </select>
                    <p className="text-xs text-gray-500 mt-1">{t('processing.form.workOrderHint')}</p>
                </div>

                {/* 加工日期 —— 必填(决定分录期间)。预填今天是【便利】不是默认值:
                    记录加工的通常就是当天开工的人;清空则禁钮并在按钮旁点名。 */}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('processing.form.dateLabel')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="date"
                        required
                        value={processDate}
                        onChange={(e) => setProcessDate(e.target.value)}
                        onBlur={(e) => setProcessDate(e.target.value)}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                {/* PROC-WIRE-1B-i:这一炉跑哪一道工序 —— 它决定收什么料、产不产批,
                    以及那道【起火】闸受理哪些安全状态。 */}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('processing.form.operationLabel')} <span className="text-red-600">*</span>
                    </label>
                    <select
                        value={operationCode}
                        onChange={(e) => setOperationCode(e.target.value)}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="">{t('processing.form.operationPlaceholder')}</option>
                        {operations.map((o) => (
                            <option key={o.code} value={o.code}>
                                {locale === 'zh' ? o.name_zh : o.name_en}
                            </option>
                        ))}
                    </select>
                    {/* 【收什么形态,照字典画出来】操作员不必去猜这台机器吃不吃这批料。 */}
                    {operation && (
                        <p className="text-xs text-gray-600 mt-1">
                            {t('processing.form.operationAccepts', {
                                forms: operation.input_forms
                                    .map((f) => (locale === 'zh' ? f.name_zh : f.name_en))
                                    .join(locale === 'zh' ? '、' : ', '),
                            })}
                        </p>
                    )}
                    {operation && !producesOutputs && (
                        <p className="text-xs text-amber-700 mt-1">
                            {t('processing.form.operationNoOutputs')}
                        </p>
                    )}
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
                        const selectedBatch = (row.batch_ref.startsWith('out:') ? outputBatches : inboundBatches)
                            .find((b) => b.id === row.batch_ref.slice(row.batch_ref.indexOf(':') + 1))
                        const qtyNum = Number(row.quantity_consumed)
                        const exceeds =
                            selectedBatch &&
                            !Number.isNaN(qtyNum) &&
                            qtyNum > selectedBatch.available_qty
                        return (
                            <div key={row.key}>
                                <div className="flex gap-2 items-start">
                                    <select
                                        value={row.batch_ref}
                                        onChange={(e) =>
                                            updateInputRow(row.key, {
                                                batch_ref: e.target.value,
                                            })
                                        }
                                        className="flex-1 border border-gray-300 px-3 py-2 rounded"
                                    >
                                        <option value="" disabled>
                                            {t('processing.form.selectInboundBatch')}
                                        </option>
                                        <optgroup label={t('processing.form.groupInbound')}>
                                            {inboundBatches.map((b) => (
                                                <option key={b.id} value={'in:' + b.id}>
                                                    {t('processing.form.inboundOptionLabel', {
                                                        code: b.code,
                                                        name: b.materials?.name ?? '—',
                                                        remaining: b.available_qty,
                                                        unit: b.unit,
                                                    })}
                                                </option>
                                            ))}
                                        </optgroup>
                                        {/* FIN-25:再加工 —— 产出批喂回下一段 */}
                                        {outputBatches.length > 0 && (
                                            <optgroup label={t('processing.form.groupOutput')}>
                                                {outputBatches.map((b) => (
                                                    <option key={b.id} value={'out:' + b.id}>
                                                        {t('processing.form.inboundOptionLabel', {
                                                            code: b.code,
                                                            name: b.materials?.name ?? '—',
                                                            remaining: b.available_qty,
                                                            unit: b.unit,
                                                        })}
                                                    </option>
                                                ))}
                                            </optgroup>
                                        )}
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
                {/* PROC-WIRE-1B-i:不产出的工序【连产出区都不画】——
                    画一个"填了就会被拒"的区域,是在制造一个必然的错误。 */}
                {producesOutputs && (
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
                )}

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

                {/* 提交按钮 —— 禁用必须说出为什么(CMP-2):每个禁钮条件都有紧邻的一行字。 */}
                {!processDate && (
                    <p className="text-sm text-amber-700">{t('processing.form.blockedProcessDate')}</p>
                )}
                <div className="flex gap-3 pt-4">
                    <Button
                        type="submit"
                        disabled={isPending || !processDate}
                    >
                        {isPending ? t('processing.form.saving') : t('processing.form.saveRun')}
                    </Button>
                    <Link
                        href="/operation/processing"
                        className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                    >
                        {t('common.cancel')}
                    </Link>
                </div>
            </form>
        </div>
    )
}
