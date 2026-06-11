'use client'

import { useActionState } from 'react'
import Link from 'next/link'
import { createMaterial, type CreateMaterialState } from './actions'
import CustomSelect from '../CustomSelect'
import { CATEGORY_OPTIONS, CHEMISTRY_OPTIONS, UNIT_OPTIONS } from '../options'

const initialState: CreateMaterialState = {}

export default function NewMaterialPage() {
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
                    ← 返回列表
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-6">新增物料</h1>

            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            <form action={formAction} className="space-y-4">
                {/* 名称(必填)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        名称 <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="name"
                        required
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                        placeholder="例如:NMC极片 / 三元黑粉 / 铜"
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
                        label="类别"
                        options={CATEGORY_OPTIONS}
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
                        label="化学体系"
                        options={CHEMISTRY_OPTIONS}
                    />
                </div>

                {/* 单位(固定列表)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">单位</label>
                    <select
                        name="unit"
                        defaultValue="kg"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        {UNIT_OPTIONS.map((u) => (
                            <option key={u} value={u}>
                                {u}
                            </option>
                        ))}
                    </select>
                </div>

                {/* 规格/描述 */}
                <div>
                    <label className="block text-sm font-medium mb-1">规格/描述</label>
                    <input
                        type="text"
                        name="spec"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                {/* 备注 */}
                <div>
                    <label className="block text-sm font-medium mb-1">备注</label>
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
                        {isPending ? '保存中...' : '保存'}
                    </button>
                    <Link
                        href="/materials"
                        className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                    >
                        取消
                    </Link>
                </div>
            </form>
        </div>
    )
}
