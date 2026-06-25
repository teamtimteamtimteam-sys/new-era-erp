'use client'

import { useActionState } from 'react'
import Link from 'next/link'
import { updateMaterial, type UpdateMaterialState } from './actions'
import CustomSelect from '../../CustomSelect'
import {
    CATEGORY_OPTIONS,
    CHEMISTRY_OPTIONS,
    UNIT_OPTIONS,
    CUSTOM_VALUE,
} from '../../options'
import { useTranslations } from '@/lib/i18n/client'

const initialState: UpdateMaterialState = {}

type Material = {
    id: string
    name: string
    category: string
    chemistry: string | null
    unit: string
    spec: string | null
    notes: string | null
}

export default function EditMaterialForm({ material }: { material: Material }) {
    const t = useTranslations()
    const updateWithId = updateMaterial.bind(null, material.id)
    const [state, formAction, isPending] = useActionState(
        updateWithId,
        initialState
    )

    const categoryOptions = CATEGORY_OPTIONS.map((o) => ({
        value: o.value,
        label: t(o.labelKey),
    }))
    const chemistryOptions = CHEMISTRY_OPTIONS.map((o) => ({
        value: o.value,
        label: t(o.labelKey),
    }))

    return (
        <>
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            <form action={formAction} className="space-y-4">
                {/* 名称(必填)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('materials.form.name')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="name"
                        required
                        defaultValue={material.name}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                    {state.fieldErrors?.name && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.name}
                        </p>
                    )}
                </div>

                {/* 类别(必填,可自定义)*/}
                <div>
                    <CustomSelect
                        name="category"
                        label={t('materials.form.category')}
                        placeholder={t('materials.form.selectPlaceholder', {
                            label: t('materials.form.category'),
                        })}
                        options={categoryOptions}
                        customValue={CUSTOM_VALUE}
                        customInputPlaceholder={t('materials.form.customPlaceholder', {
                            label: t('materials.form.category'),
                        })}
                        required
                        defaultValue={material.category}
                    />
                    {state.fieldErrors?.category && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.category}
                        </p>
                    )}
                </div>

                {/* 化学体系(可选,可自定义)*/}
                <div>
                    <CustomSelect
                        name="chemistry"
                        label={t('materials.form.chemistry')}
                        placeholder={t('materials.form.selectPlaceholder', {
                            label: t('materials.form.chemistry'),
                        })}
                        options={chemistryOptions}
                        customValue={CUSTOM_VALUE}
                        customInputPlaceholder={t('materials.form.customPlaceholder', {
                            label: t('materials.form.chemistry'),
                        })}
                        defaultValue={material.chemistry ?? undefined}
                    />
                </div>

                {/* 单位(固定列表)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('materials.form.unit')}</label>
                    <select
                        name="unit"
                        defaultValue={material.unit}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        {UNIT_OPTIONS.map((u) => (
                            <option key={u.value} value={u.value}>
                                {t(u.labelKey)}
                            </option>
                        ))}
                    </select>
                </div>

                {/* 规格/描述 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('materials.form.spec')}</label>
                    <input
                        type="text"
                        name="spec"
                        defaultValue={material.spec ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                {/* 备注 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('materials.form.notes')}</label>
                    <textarea
                        name="notes"
                        rows={3}
                        defaultValue={material.notes ?? ''}
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
                        href="/materials"
                        className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                    >
                        {t('common.cancel')}
                    </Link>
                </div>
            </form>
        </>
    )
}
