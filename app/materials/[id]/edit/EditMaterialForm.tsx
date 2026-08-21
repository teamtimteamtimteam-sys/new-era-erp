'use client'

import { useActionState } from 'react'
import Link from 'next/link'
import { updateMaterial, type UpdateMaterialState } from './actions'
import MaterialKindPicker from '../../MaterialKindPicker'
import type { MaterialKind } from '../../materialKindOptions'
import CustomSelect from '../../CustomSelect'
import {
    CHEMISTRY_OPTIONS,
    UNIT_OPTIONS,
    CUSTOM_VALUE,
} from '../../options'
import { useTranslations } from '@/lib/i18n/client'
import WasteClassPicker from '../../WasteClassPicker'
import type { WasteClass } from '../../wasteClassOptions'

const initialState: UpdateMaterialState = {}

type Material = {
    id: string
    name: string
    kind_code: string | null
    may_be_processed: boolean | null
    chemistry: string | null
    waste_classification_code: string | null
    unit: string
    spec: string | null
    notes: string | null
    safety_stock_qty: number | null
}

export default function EditMaterialForm({
    material,
    wasteClasses,
    kinds,
    locale,
}: {
    material: Material
    wasteClasses: WasteClass[]
    kinds: MaterialKind[]
    locale: string
}) {
    const t = useTranslations()
    const updateWithId = updateMaterial.bind(null, material.id)
    const [state, formAction, isPending] = useActionState(
        updateWithId,
        initialState
    )

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

                {/* PROC-1:种类(字典)+ 能不能投料。
                    【既有物料两列都是空的 —— 那是"没有人决定过",而它是真话】
                    materials_kind_stated 是 NOT VALID 的:它对 UPDATE 也生效,
                    所以这一行【在有人把种类说出来之前存不下去】。那是想要的行为,
                    而屏幕上由 MaterialKindPicker 那句琥珀色的话说出来,
                    不是漏一条裸约束名出去。 */}
                <MaterialKindPicker kinds={kinds} defaultKind={material.kind_code}
                    defaultProcessable={material.may_be_processed} locale={locale} />
                {state.fieldErrors?.kind_code && (
                    <p className="text-red-600 text-xs -mt-2">{state.fieldErrors.kind_code}</p>
                )}
                {state.fieldErrors?.may_be_processed && (
                    <p className="text-red-600 text-xs -mt-2">{state.fieldErrors.may_be_processed}</p>
                )}

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

                {/* MAT-1:受控废物分类。改回【未分类】是正当的动作(录错了要能撤回),
                    而不是一个应当被拦住的状态。 */}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('materials.form.wasteClass')}
                    </label>
                    <WasteClassPicker name="waste_classification_code" classes={wasteClasses}
                        defaultValue={material.waste_classification_code} locale={locale} />
                    <p className="text-xs text-gray-500 mt-1">{t('materials.form.wasteClassHint')}</p>
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

                {/* SS-1:安全库存阈值。【留空 = 不监控】—— 那是一个还没有人做过的
                    决定,不是"阈值为零";旁边那句话必须在,否则留空会被读成"没事"。 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('materials.form.safetyStock')}</label>
                    <input
                        type="number"
                        step="any"
                        min="0"
                        name="safety_stock_qty"
                        defaultValue={material.safety_stock_qty ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                    {state.fieldErrors?.safety_stock_qty && (
                        <p className="text-red-600 text-xs mt-1">{state.fieldErrors.safety_stock_qty}</p>
                    )}
                    <p className="text-xs text-gray-500 mt-1">{t('materials.form.safetyStockHint')}</p>
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
