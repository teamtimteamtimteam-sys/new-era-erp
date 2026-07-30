'use client'

import { useActionState } from 'react'
import Link from 'next/link'
import { updateInbound, type UpdateInboundState } from './actions'
import { UNIT_OPTIONS } from '../../../materials/options'
import { STAGE_OPTIONS } from '../../options'
import { useTranslations } from '@/lib/i18n/client'

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
    const t = useTranslations()
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
                        {t('inbound.form.material')} <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="material_id"
                        required
                        defaultValue={batch.material_id}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="" disabled>{t('inbound.form.selectMaterial')}</option>
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
                            {t('inbound.form.noMaterialsHelper')}
                            <Link href="/materials/new" className="underline">
                                {t('inbound.form.noMaterialsLink')}
                            </Link>
                            {t('inbound.form.noMaterialsHelperPost')}
                        </p>
                    )}
                </div>

                {/* 供应商(必填,预选)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('inbound.form.supplier')} <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="supplier_id"
                        required
                        defaultValue={batch.supplier_id}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="" disabled>{t('inbound.form.selectSupplier')}</option>
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
                            {t('inbound.form.noSuppliersHelper')}
                            <Link href="/suppliers/new" className="underline">
                                {t('inbound.form.noSuppliersLink')}
                            </Link>
                            {t('inbound.form.noSuppliersHelperPost')}
                        </p>
                    )}
                </div>

                {/* 数量(创建后锁定 —— 库存变动走库存流水;disabled 不随表单提交)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('inbound.form.quantity')}</label>
                    <input
                        type="number"
                        name="quantity"
                        step="any"
                        disabled
                        defaultValue={batch.quantity}
                        className="w-full border border-gray-300 px-3 py-2 rounded bg-gray-100 text-gray-500"
                    />
                    <p className="text-xs text-gray-500 mt-1">{t('inbound.edit.quantityLockedHint')}</p>
                </div>

                {/* 单位 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('inbound.form.unit')}</label>
                    <select
                        name="unit"
                        defaultValue={batch.unit}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        {UNIT_OPTIONS.map((u) => (
                            <option key={u.value} value={u.value}>
                                {t(u.labelKey)}
                            </option>
                        ))}
                    </select>
                </div>

                {/* 剩余可用量(只读)*/}
                <p className="text-sm text-gray-600 bg-gray-50 px-3 py-2 rounded">
                    {t('inbound.form.remainingLine', {
                        qty: batch.remaining_qty,
                        unit: batch.unit,
                    })}
                </p>

                {/* 到货日期 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('inbound.form.arrivalDate')}</label>
                    <input
                        type="date"
                        name="arrival_date"
                        defaultValue={batch.arrival_date ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                {/* 阶段 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('inbound.form.stage')}</label>
                    <select
                        name="stage"
                        defaultValue={batch.stage}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        {STAGE_OPTIONS.map((s) => (
                            <option key={s.value} value={s.value}>
                                {t(s.labelKey)}
                            </option>
                        ))}
                    </select>
                </div>

                {/* 单价(cut 1 起锁定 —— 变更必须走下方计价面板留痕;disabled 不随表单提交)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('inbound.form.unitPrice')}</label>
                    <input
                        type="number"
                        name="unit_price"
                        step="any"
                        disabled
                        defaultValue={batch.unit_price ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded bg-gray-100 text-gray-500"
                    />
                    <p className="text-xs text-gray-500 mt-1">{t('inbound.edit.priceLockedHint')}</p>
                </div>

                {/* 备注 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('inbound.form.notes')}</label>
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
                        {isPending ? t('common.saving') : t('common.save')}
                    </button>
                    <Link
                        href="/inbound"
                        className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                    >
                        {t('common.cancel')}
                    </Link>
                </div>
            </form>
        </>
    )
}
