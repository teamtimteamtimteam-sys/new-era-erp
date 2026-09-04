'use client'

import { useActionState } from 'react'
import Link from 'next/link'
import { updateOutput, type UpdateOutputState } from './actions'
import { UNIT_OPTIONS } from '../../../materials/options'
import { STATE_OPTIONS } from '../../../inbound/options'
import { useTranslations } from '@/lib/i18n/client'

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
    const t = useTranslations()
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
                        {t('output.form.material')} <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="material_id"
                        required
                        defaultValue={batch.material_id}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="" disabled>{t('output.form.selectMaterial')}</option>
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
                            {t('output.form.noMaterialsHelper')}
                            <Link href="/materials/new" className="underline">
                                {t('output.form.noMaterialsLink')}
                            </Link>
                            {t('output.form.noMaterialsHelperPost')}
                        </p>
                    )}
                </div>

                {/* 客户(可选,预选)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('output.form.customer')}</label>
                    <select
                        name="customer_id"
                        defaultValue={batch.customer_id ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="">{t('output.form.selectCustomerOptional')}</option>
                        {customers.map((c) => (
                            <option key={c.id} value={c.id}>
                                {c.code} - {c.legal_name}
                            </option>
                        ))}
                    </select>
                    {customers.length === 0 && (
                        <p className="text-xs text-amber-600 mt-1">
                            {t('output.form.noCustomersHelper')}
                            <Link href="/sales/customers/new" className="underline">
                                {t('output.form.noCustomersLink')}
                            </Link>
                            {t('output.form.noCustomersHelperPost')}
                        </p>
                    )}
                </div>

                {/* 数量(创建后锁定 —— 库存变动走库存流水;disabled 不随表单提交)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('output.form.quantity')}</label>
                    <input
                        type="number"
                        name="quantity"
                        step="any"
                        disabled
                        defaultValue={batch.quantity}
                        className="w-full border border-gray-300 px-3 py-2 rounded bg-gray-100 text-gray-500"
                    />
                    <p className="text-xs text-gray-500 mt-1">{t('output.edit.quantityLockedHint')}</p>
                </div>

                {/* 单位 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('output.form.unit')}</label>
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

                {/* 剩余可售量(只读)*/}
                <p className="text-sm text-gray-600 bg-gray-50 px-3 py-2 rounded">
                    {t('output.form.remainingLine', {
                        qty: batch.remaining_qty,
                        unit: batch.unit,
                    })}
                </p>

                {/* 产出日期 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('output.form.outputDate')}</label>
                    <input
                        type="date"
                        name="output_date"
                        defaultValue={batch.output_date ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                {/* 状态(由销售/加工自动更新 —— 只读;disabled 不随表单提交)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('output.form.state')}</label>
                    <select
                        name="state"
                        disabled
                        defaultValue={batch.state}
                        className="w-full border border-gray-300 px-3 py-2 rounded bg-gray-100 text-gray-500"
                    >
                        {STATE_OPTIONS.map((s) => (
                            <option key={s.value} value={s.value}>
                                {t(s.labelKey)}
                            </option>
                        ))}
                    </select>
                    <p className="text-xs text-gray-500 mt-1">{t('output.edit.stateLockedHint')}</p>
                </div>

                {/* 品位/纯度 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('output.form.purity')}</label>
                    <input
                        type="text"
                        name="purity"
                        defaultValue={batch.purity ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                        placeholder={t('output.form.purityPlaceholder')}
                    />
                </div>

                {/* 备注 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('output.form.notes')}</label>
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
                        href="/output"
                        className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                    >
                        {t('common.cancel')}
                    </Link>
                </div>
            </form>
        </>
    )
}
