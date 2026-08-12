'use client'

import { useActionState } from 'react'
import Link from 'next/link'
import { createOutput, type CreateOutputState } from './actions'
import { UNIT_OPTIONS } from '../../materials/options'
import { STATE_OPTIONS } from '../../inbound/options'
import { useTranslations } from '@/lib/i18n/client'
import LocationPicker, { type LocationChoice } from '@/app/components/inventory/LocationPicker'

const initialState: CreateOutputState = {}

type MaterialOption = { id: string; code: string; name: string }
type CustomerOption = { id: string; code: string; legal_name: string }

export default function NewOutputForm({
    locations,
    materials,
    customers,
}: {
    // IOD-1b:收货库位的可选清单(在用库位),由页面取好传进来
    locations: LocationChoice[]
    materials: MaterialOption[]
    customers: CustomerOption[]
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(
        createOutput,
        initialState
    )

    return (
        <div className="p-8 max-w-2xl">
            <div className="mb-6">
                <Link
                    href="/output"
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-6">{t('output.newTitle')}</h1>

            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            <form action={formAction} className="space-y-4">
            {/* IOD-1b:收货库位(可选)。默认「未指定 —— 之后用转移指定」 */}
            <LocationPicker locations={locations} />
                {/* 物料(必填)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('output.form.material')} <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="material_id"
                        required
                        defaultValue=""
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

                {/* 客户(可选)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('output.form.customer')}</label>
                    <select
                        name="customer_id"
                        defaultValue=""
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
                            <Link href="/customers/new" className="underline">
                                {t('output.form.noCustomersLink')}
                            </Link>
                            {t('output.form.noCustomersHelperPost')}
                        </p>
                    )}
                </div>

                {/* 数量(必填)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('output.form.quantity')} <span className="text-red-600">*</span>
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
                    <label className="block text-sm font-medium mb-1">{t('output.form.unit')}</label>
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

                {/* 产出日期 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('output.form.outputDate')}</label>
                    <input
                        type="date"
                        name="output_date"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                {/* 状态 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('output.form.state')}</label>
                    <select
                        name="state"
                        defaultValue="库存中"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        {STATE_OPTIONS.map((s) => (
                            <option key={s.value} value={s.value}>
                                {t(s.labelKey)}
                            </option>
                        ))}
                    </select>
                </div>

                {/* 品位/纯度 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('output.form.purity')}</label>
                    <input
                        type="text"
                        name="purity"
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
        </div>
    )
}
