'use client'
// app/materials/new/NewMaterialForm.tsx
// OPS-15:本文件是原 page.tsx 的表单本体,原样搬过来 —— 一行渲染逻辑都没改。
// 搬家的理由只有一个:它是 'use client',而模块守卫 requireModule() 是服务端的
// (它 await 权限、读 cookie 取语言)。守卫塞进客户端组件会把 next/headers 拖进
// 客户端图,整个构建失败;而且客户端组件不能是 async。
// 所以守卫回到 page.tsx 那层服务端壳里,与 app/metal-prices/new 早就在用的形状一致。
import { useActionState } from 'react'
import Link from 'next/link'
import { createMaterial, type CreateMaterialState } from './actions'
import CustomSelect from '../CustomSelect'
import {
    CATEGORY_OPTIONS,
    CHEMISTRY_OPTIONS,
    UNIT_OPTIONS,
    CUSTOM_VALUE,
} from '../options'
import { useTranslations } from '@/lib/i18n/client'

const initialState: CreateMaterialState = {}

export default function NewMaterialForm() {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(
        createMaterial,
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
                    />
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
