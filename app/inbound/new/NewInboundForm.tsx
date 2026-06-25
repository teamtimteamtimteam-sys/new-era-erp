'use client'

import { useActionState } from 'react'
import Link from 'next/link'
import { createInbound, type CreateInboundState } from './actions'
import { UNIT_OPTIONS } from '../../materials/options'
import { STAGE_OPTIONS } from '../options'
import { useTranslations } from '@/lib/i18n/client'

const initialState: CreateInboundState = {}

type MaterialOption = { id: string; code: string; name: string }
type SupplierOption = { id: string; code: string; legal_name: string }

export default function NewInboundForm({
    materials,
    suppliers,
}: {
    materials: MaterialOption[]
    suppliers: SupplierOption[]
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(
        createInbound,
        initialState
    )

    return (
        <div className="p-8 max-w-2xl">
            <div className="mb-6">
                <Link
                    href="/inbound"
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-6">{t('inbound.newTitle')}</h1>

            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            <form action={formAction} className="space-y-4">
                {/* 物料(必填)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('inbound.form.material')} <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="material_id"
                        required
                        defaultValue=""
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

                {/* 供应商(必填)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('inbound.form.supplier')} <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="supplier_id"
                        required
                        defaultValue=""
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

                {/* 数量(必填)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('inbound.form.quantity')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="number"
                        name="quantity"
                        required
                        step="any"
                        min="0"
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
                    <label className="block text-sm font-medium mb-1">{t('inbound.form.unit')}</label>
                    <select
                        name="unit"
                        defaultValue="kg"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        {UNIT_OPTIONS.map((u) => (
                            <option key={u.value} value={u.value}>
                                {t(u.labelKey)}
                            </option>
                        ))}
                    </select>
                </div>

                {/* 到货日期 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('inbound.form.arrivalDate')}</label>
                    <input
                        type="date"
                        name="arrival_date"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                {/* 阶段 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('inbound.form.stage')}</label>
                    <select
                        name="stage"
                        defaultValue="待加工"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        {STAGE_OPTIONS.map((s) => (
                            <option key={s.value} value={s.value}>
                                {t(s.labelKey)}
                            </option>
                        ))}
                    </select>
                </div>

                {/* 单价 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('inbound.form.unitPrice')}</label>
                    <input
                        type="number"
                        name="unit_price"
                        step="any"
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
                    <label className="block text-sm font-medium mb-1">{t('inbound.form.notes')}</label>
                    <textarea
                        name="notes"
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
        </div>
    )
}
