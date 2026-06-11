'use client'

import { useActionState } from 'react'
import Link from 'next/link'
import { createCustomer, type CreateCustomerState } from './actions'

const CUSTOMER_TYPE_OPTIONS = [
    { value: 'cathode_maker', label: '正极材料厂' },
    { value: 'battery_factory', label: '电池厂' },
    { value: 'trader', label: '贸易商' },
    { value: 'other', label: '其他' },
]

const initialState: CreateCustomerState = {}

export default function NewCustomerPage() {
    const [state, formAction, isPending] = useActionState(
        createCustomer,
        initialState
    )

    return (
        <div className="p-8 max-w-2xl">
            <div className="mb-6">
                <Link
                    href="/customers"
                    className="text-blue-600 hover:underline text-sm"
                >
                    ← 返回列表
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-6">新增客户</h1>

            {/* 通用错误显示 */}
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            <form action={formAction} className="space-y-4">
                {/* 法人名(必填) */}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        法人名 <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="legal_name"
                        required
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                        placeholder="例如:Acme Cathode Materials Pte Ltd"
                    />
                    {state.fieldErrors?.legal_name && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.legal_name}
                        </p>
                    )}
                </div>

                {/* 简称 */}
                <div>
                    <label className="block text-sm font-medium mb-1">简称</label>
                    <input
                        type="text"
                        name="short_name"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                        placeholder="例如:Acme"
                    />
                </div>

                {/* 国家(必填) */}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        国家(2 字母代码) <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="country"
                        required
                        maxLength={2}
                        className="w-full border border-gray-300 px-3 py-2 rounded uppercase"
                        placeholder="例如:SG, CN, DE, US"
                    />
                    {state.fieldErrors?.country && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.country}
                        </p>
                    )}
                </div>

                {/* 税号 */}
                <div>
                    <label className="block text-sm font-medium mb-1">税号</label>
                    <input
                        type="text"
                        name="tax_id"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                {/* 地址 */}
                <div>
                    <label className="block text-sm font-medium mb-1">地址</label>
                    <textarea
                        name="address"
                        rows={2}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                {/* 客户类型(多选) */}
                <div>
                    <label className="block text-sm font-medium mb-2">
                        客户类型(可多选)
                    </label>
                    <div className="space-y-2">
                        {CUSTOMER_TYPE_OPTIONS.map((opt) => (
                            <label key={opt.value} className="flex items-center gap-2">
                                <input
                                    type="checkbox"
                                    name="customer_types"
                                    value={opt.value}
                                    className="w-4 h-4"
                                />
                                <span className="text-sm">{opt.label}</span>
                            </label>
                        ))}
                    </div>
                </div>

                {/* 付款条款 */}
                <div>
                    <label className="block text-sm font-medium mb-1">付款条款</label>
                    <input
                        type="text"
                        name="payment_terms"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                        placeholder="例如:NET30, NET60, CIA, LC at sight"
                    />
                </div>

                {/* Incoterm */}
                <div>
                    <label className="block text-sm font-medium mb-1">Incoterm</label>
                    <input
                        type="text"
                        name="incoterm"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                        placeholder="例如:FOB, CIF, EXW, DDP"
                    />
                </div>

                {/* 信用评级 */}
                <div>
                    <label className="block text-sm font-medium mb-1">信用评级</label>
                    <input
                        type="text"
                        name="credit_rating"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                        placeholder="例如:A, B, C 或内部评级"
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
                        href="/customers"
                        className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                    >
                        取消
                    </Link>
                </div>
            </form>
        </div>
    )
}
