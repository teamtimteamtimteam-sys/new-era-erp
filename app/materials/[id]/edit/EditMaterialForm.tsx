'use client'

import type { DictOption } from '@/app/components/dictionaries/dictionaryQuery'
import { useActionState } from 'react'
import Link from 'next/link'
import { updateMaterial, type UpdateMaterialState } from './actions'
import MaterialAxesPicker from '../../MaterialAxesPicker'
import type { MaterialKind } from '../../materialKindOptions'
import type { MaterialForm, MaterialSource, MaterialSizeFormat } from '../../materialAxesOptions'
import {
    UNIT_OPTIONS,
} from '../../options'
import { useTranslations } from '@/lib/i18n/client'
import WasteClassPicker from '../../WasteClassPicker'
import type { WasteClass } from '../../wasteClassOptions'
import { Button } from '@/app/components/ui/button'

const initialState: UpdateMaterialState = {}

type Material = {
    id: string
    name: string
    kind_code: string | null
    may_be_processed: boolean | null
    form_code: string | null
    source_code: string | null
    size_format_code: string | null
    chemistry: string | null
    waste_classification_code: string | null
    unit: string
    spec: string | null
    notes: string | null
    safety_stock_qty: number | null
}

export default function EditMaterialForm({
    chemistryOptions,
    material,
    wasteClasses,
    kinds,
    forms,
    sources,
    sizeFormats,
    locale,
}: {
    // PROC-5:化学体系字典(值 + 已翻好的名字),由页面读好传进来
    chemistryOptions: DictOption[]
    material: Material
    wasteClasses: WasteClass[]
    kinds: MaterialKind[]
    forms: MaterialForm[]
    sources: MaterialSource[]
    sizeFormats: MaterialSizeFormat[]
    locale: string
}) {
    const t = useTranslations()
    const updateWithId = updateMaterial.bind(null, material.id)
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
                <MaterialAxesPicker kinds={kinds} forms={forms} sources={sources} sizeFormats={sizeFormats}
                    defaultKind={material.kind_code} defaultProcessable={material.may_be_processed}
                    defaultForm={material.form_code} defaultSource={material.source_code}
                    defaultSizeFormat={material.size_format_code} locale={locale} />
                {state.fieldErrors?.kind_code && (
                    <p className="text-red-600 text-xs -mt-2">{state.fieldErrors.kind_code}</p>
                )}
                {state.fieldErrors?.may_be_processed && (
                    <p className="text-red-600 text-xs -mt-2">{state.fieldErrors.may_be_processed}</p>
                )}
                {(['form_code', 'source_code', 'size_format_code'] as const).map((f) =>
                    state.fieldErrors?.[f]
                        ? <p key={f} className="text-red-600 text-xs -mt-2">{state.fieldErrors[f]}</p>
                        : null)}

                {/* 化学体系(可选,可自定义)*/}
                <div>
                    {/* PROC-5:化学体系 —— 字典下拉,【没有自由文本口了】。
                        从前这里是 CustomSelect,选中「其他」会打开一个文本框;
                        那个口就是 F7 点名的病本身(线上已经从它进来过一个占位串)。
                        加一种化学体系现在 = 往字典里加一行。
                        【留空仍然合法】它的意思是"没有人记过",不是"不适用"
                        —— 后者由物料种类回答。 */}
                    <label className="block text-sm font-medium mb-1">
                        {t('materials.form.chemistry')}
                    </label>
                    <select
                        name="chemistry"
                        defaultValue={material.chemistry ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="">{t('materials.form.selectPlaceholder', {
                            label: t('materials.form.chemistry'),
                        })}</option>
                        {/* 选单只列还能【新选】的;而上面那个 defaultValue 即使指向
                            一个已停用的取值,也照样显示 —— 两个动词,两处判断。 */}
                        {chemistryOptions.filter((o) => o.isActive || o.value === material.chemistry).map((o) => (
                            <option key={o.value} value={o.value}>{o.label}</option>
                        ))}
                    </select>
                    {/* DICT-ADMIN:同上 —— 那句"还没有页面"换成一条真链接。 */}
                    <p className="text-xs text-gray-500 mt-1">
                        {t('materials.form.chemistryAddHint')}{' '}
                        <a href="/settings/dictionaries" className="text-blue-600 underline">
                            {t('dict.title')}
                        </a>
                    </p>
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
                    <Button
                        type="submit"
                        disabled={isPending}
                    >
                        {isPending ? t('common.saving') : t('common.save')}
                    </Button>
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
