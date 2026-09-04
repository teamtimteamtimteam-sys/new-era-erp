'use client'
// app/materials/new/NewMaterialForm.tsx
// OPS-15:本文件是原 page.tsx 的表单本体,原样搬过来 —— 一行渲染逻辑都没改。
// 搬家的理由只有一个:它是 'use client',而模块守卫 requireModule() 是服务端的
// (它 await 权限、读 cookie 取语言)。守卫塞进客户端组件会把 next/headers 拖进
// 客户端图,整个构建失败;而且客户端组件不能是 async。
// 所以守卫回到 page.tsx 那层服务端壳里,与 app/tools/pricing/metal-prices/new 早就在用的形状一致。
import type { DictOption } from '@/app/components/dictionaries/dictionaryQuery'
import { useActionState } from 'react'
import Link from 'next/link'
import { createMaterial, type CreateMaterialState } from './actions'
import MaterialAxesPicker from '../MaterialAxesPicker'
import type { MaterialKind } from '../materialKindOptions'
import type { MaterialForm, MaterialSource, MaterialSizeFormat } from '../materialAxesOptions'
import {
    UNIT_OPTIONS,
} from '../options'
import { useTranslations } from '@/lib/i18n/client'
import WasteClassPicker from '../WasteClassPicker'
import type { WasteClass } from '../wasteClassOptions'

const initialState: CreateMaterialState = {}

export default function NewMaterialForm({
    chemistryOptions,
    wasteClasses,
    kinds,
    forms,
    sources,
    sizeFormats,
    locale,
}: {
    // PROC-5:化学体系字典(值 + 已翻好的名字),由页面读好传进来
    chemistryOptions: DictOption[]
    wasteClasses: WasteClass[]
    kinds: MaterialKind[]
    forms: MaterialForm[]
    sources: MaterialSource[]
    sizeFormats: MaterialSizeFormat[]
    locale: string
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(
        createMaterial,
        initialState
    )


    return (
        <div className="p-8 max-w-2xl">
            <div className="mb-6">
                <Link
                    href="/materials"
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-6">{t('materials.newTitle')}</h1>

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
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                        placeholder={t('materials.form.namePlaceholder')}
                    />
                    {state.fieldErrors?.name && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.name}
                        </p>
                    )}
                </div>

                {/* PROC-1:种类(字典)+ 能不能投料(明说出来的选择,不给默认)*/}
                <MaterialAxesPicker kinds={kinds} forms={forms} sources={sources} sizeFormats={sizeFormats}
                    defaultKind={null} defaultProcessable={null}
                    defaultForm={null} defaultSource={null} defaultSizeFormat={null} locale={locale} />
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
                        defaultValue={''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="">{t('materials.form.selectPlaceholder', {
                            label: t('materials.form.chemistry'),
                        })}</option>
                        {/* 选单只列还能【新选】的;而上面那个 defaultValue 即使指向
                            一个已停用的取值,也照样显示 —— 两个动词,两处判断。 */}
                        {chemistryOptions.filter((o) => o.isActive || o.value === '').map((o) => (
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


                {/* MAT-1:受控废物分类。【未分类是一个要选的选项,不是留空】——
                    它的意思是"没有人分过类",与"分类为非受控"在合规判断上不是一回事。 */}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('materials.form.wasteClass')}
                    </label>
                    <WasteClassPicker name="waste_classification_code" classes={wasteClasses}
                        defaultValue={null} locale={locale} />
                    <p className="text-xs text-gray-500 mt-1">{t('materials.form.wasteClassHint')}</p>
                </div>

                {/* 单位(固定列表)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('materials.form.unit')}</label>
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

                {/* 规格/描述 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('materials.form.spec')}</label>
                    <input
                        type="text"
                        name="spec"
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
        </div>
    )
}
