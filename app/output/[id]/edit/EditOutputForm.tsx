'use client'

import { useActionState } from 'react'
import Link from 'next/link'
import { updateOutput, type UpdateOutputState } from './actions'
import { UNIT_OPTIONS } from '../../../materials/options'
import { STATE_OPTIONS } from '../../../inbound/options'

const initialState: UpdateOutputState = {}

type Batch = {
    id: string
    material_id: string
    customer_id: string | null
    quantity: number
    unit: string
    remaining_qty: number
    output_date: string | null
    state: string
    purity: string | null
    notes: string | null
}

type MaterialOption = { id: string; code: string; name: string }
type CustomerOption = { id: string; code: string; legal_name: string }

export default function EditOutputForm({
    batch,
    materials,
    customers,
}: {
    batch: Batch
    materials: MaterialOption[]
    customers: CustomerOption[]
}) {
    const updateWithId = updateOutput.bind(null, batch.id)
    const [state, formAction, isPending] = useActionState(
        updateWithId,
        initialState
    )

    return (
        <>
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            <form action={formAction} className="space-y-4">
                {/* 物料(必填,预选)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        物料 <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="material_id"
                        required
                        defaultValue={batch.material_id}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="" disabled>请选择物料</option>
                        {materials.map((m) => (
                            <option key={m.id} value={m.id}>
                                {m.code} - {m.name}
                            </option>
                        ))}
                    </select>
                    {state.fieldErrors?.material_id && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.material_id}
                        </p>
                    )}
                    {materials.length === 0 && (
                        <p className="text-xs text-amber-600 mt-1">
                            还没有物料,请先到{' '}
                            <Link href="/materials/new" className="underline">
                                物料字典
                            </Link>{' '}
                            创建
                        </p>
                    )}
                </div>

                {/* 客户(可选,预选)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">客户</label>
                    <select
                        name="customer_id"
                        defaultValue={batch.customer_id ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="">请选择客户(可选)</option>
                        {customers.map((c) => (
                            <option key={c.id} value={c.id}>
                                {c.code} - {c.legal_name}
                            </option>
                        ))}
                    </select>
                    {customers.length === 0 && (
                        <p className="text-xs text-amber-600 mt-1">
                            还没有客户,可先{' '}
                            <Link href="/customers/new" className="underline">
                                创建客户
                            </Link>{' '}
                            或留空稍后再指派
                        </p>
                    )}
                </div>

                {/* 数量(必填)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        数量 <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="number"
                        name="quantity"
                        required
                        step="any"
                        min="0"
                        defaultValue={batch.quantity}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                    {state.fieldErrors?.quantity && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.quantity}
                        </p>
                    )}
                </div>

                {/* 单位 */}
                <div>
                    <label className="block text-sm font-medium mb-1">单位</label>
                    <select
                        name="unit"
                        defaultValue={batch.unit}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        {UNIT_OPTIONS.map((u) => (
                            <option key={u} value={u}>
                                {u}
                            </option>
                        ))}
                    </select>
                </div>

                {/* 剩余可售量(只读)*/}
                <p className="text-sm text-gray-600 bg-gray-50 px-3 py-2 rounded">
                    剩余可售量:{batch.remaining_qty} {batch.unit}(由销售/加工流程管理)
                </p>

                {/* 产出日期 */}
                <div>
                    <label className="block text-sm font-medium mb-1">产出日期</label>
                    <input
                        type="date"
                        name="output_date"
                        defaultValue={batch.output_date ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                {/* 状态 */}
                <div>
                    <label className="block text-sm font-medium mb-1">状态</label>
                    <select
                        name="state"
                        defaultValue={batch.state}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        {STATE_OPTIONS.map((s) => (
                            <option key={s} value={s}>
                                {s}
                            </option>
                        ))}
                    </select>
                </div>

                {/* 品位/纯度 */}
                <div>
                    <label className="block text-sm font-medium mb-1">品位/纯度</label>
                    <input
                        type="text"
                        name="purity"
                        defaultValue={batch.purity ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                        placeholder="如 Ni 22%, 三元"
                    />
                </div>

                {/* 备注 */}
                <div>
                    <label className="block text-sm font-medium mb-1">备注</label>
                    <textarea
                        name="notes"
                        rows={3}
                        defaultValue={batch.notes ?? ''}
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
                        {isPending ? '保存中...' : '保存'}
                    </button>
                    <Link
                        href="/output"
                        className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                    >
                        取消
                    </Link>
                </div>
            </form>
        </>
    )
}
