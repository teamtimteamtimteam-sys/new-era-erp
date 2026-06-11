'use client'

import { useActionState } from 'react'
import Link from 'next/link'
import { updateInbound, type UpdateInboundState } from './actions'
import { UNIT_OPTIONS } from '../../../materials/options'
import { STAGE_OPTIONS } from '../../options'

const initialState: UpdateInboundState = {}

type Batch = {
    id: string
    material_id: string
    supplier_id: string
    quantity: number
    unit: string
    remaining_qty: number
    arrival_date: string | null
    stage: string
    unit_price: number | null
    notes: string | null
}

type MaterialOption = { id: string; code: string; name: string }
type SupplierOption = { id: string; code: string; legal_name: string }

export default function EditInboundForm({
    batch,
    materials,
    suppliers,
}: {
    batch: Batch
    materials: MaterialOption[]
    suppliers: SupplierOption[]
}) {
    const updateWithId = updateInbound.bind(null, batch.id)
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

                {/* 供应商(必填,预选)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        供应商 <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="supplier_id"
                        required
                        defaultValue={batch.supplier_id}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="" disabled>请选择供应商</option>
                        {suppliers.map((s) => (
                            <option key={s.id} value={s.id}>
                                {s.code} - {s.legal_name}
                            </option>
                        ))}
                    </select>
                    {state.fieldErrors?.supplier_id && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.supplier_id}
                        </p>
                    )}
                    {suppliers.length === 0 && (
                        <p className="text-xs text-amber-600 mt-1">
                            还没有供应商,请先{' '}
                            <Link href="/suppliers/new" className="underline">
                                创建供应商
                            </Link>
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

                {/* 剩余可用量(只读)*/}
                <p className="text-sm text-gray-600 bg-gray-50 px-3 py-2 rounded">
                    剩余可用量:{batch.remaining_qty} {batch.unit}(由加工流程管理)
                </p>

                {/* 到货日期 */}
                <div>
                    <label className="block text-sm font-medium mb-1">到货日期</label>
                    <input
                        type="date"
                        name="arrival_date"
                        defaultValue={batch.arrival_date ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                {/* 阶段 */}
                <div>
                    <label className="block text-sm font-medium mb-1">阶段</label>
                    <select
                        name="stage"
                        defaultValue={batch.stage}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        {STAGE_OPTIONS.map((s) => (
                            <option key={s} value={s}>
                                {s}
                            </option>
                        ))}
                    </select>
                </div>

                {/* 单价 */}
                <div>
                    <label className="block text-sm font-medium mb-1">单价</label>
                    <input
                        type="number"
                        name="unit_price"
                        step="any"
                        defaultValue={batch.unit_price ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                    {state.fieldErrors?.unit_price && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.unit_price}
                        </p>
                    )}
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
                        href="/inbound"
                        className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                    >
                        取消
                    </Link>
                </div>
            </form>
        </>
    )
}
