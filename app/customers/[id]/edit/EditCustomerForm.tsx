'use client'

import { useActionState } from 'react'
import Link from 'next/link'
import { updateCustomer, type UpdateCustomerState } from './actions'

const CUSTOMER_TYPE_OPTIONS = [
    { value: 'cathode_maker', label: '正极材料厂' },
    { value: 'battery_factory', label: '电池厂' },
    { value: 'trader', label: '贸易商' },
    { value: 'other', label: '其他' },
]

const initialState: UpdateCustomerState = {}

type Customer = {
    id: string
    legal_name: string
    short_name: string | null
    country: string
    tax_id: string | null
    address: string | null
    customer_types: string[] | null
    payment_terms: string | null
    incoterm: string | null
    credit_rating: string | null
    notes: string | null
}

export default function EditCustomerForm({ customer }: { customer: Customer }) {
    const updateWithId = updateCustomer.bind(null, customer.id)
    const [state, formAction, isPending] = useActionState(
        updateWithId,
        initialState
    )

    const currentTypes = customer.customer_types ?? []

    return (
        <>
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            <form action={formAction} className="space-y-4">
                <div>
                    <label className="block text-sm font-medium mb-1">
                        法人名 <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="legal_name"
                        required
                        defaultValue={customer.legal_name}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                    {state.fieldErrors?.legal_name && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.legal_name}
                        </p>
                    )}
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">简称</label>
                    <input
                        type="text"
                        name="short_name"
                        defaultValue={customer.short_name ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">
                        国家(2 字母代码) <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="country"
                        required
                        maxLength={2}
                        defaultValue={customer.country}
                        className="w-full border border-gray-300 px-3 py-2 rounded uppercase"
                    />
                    {state.fieldErrors?.country && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.country}
                        </p>
                    )}
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">税号</label>
                    <input
                        type="text"
                        name="tax_id"
                        defaultValue={customer.tax_id ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">地址</label>
                    <textarea
                        name="address"
                        rows={2}
                        defaultValue={customer.address ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

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
                                    defaultChecked={currentTypes.includes(opt.value)}
                                    className="w-4 h-4"
                                />
                                <span className="text-sm">{opt.label}</span>
                            </label>
                        ))}
                    </div>
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">付款条款</label>
                    <input
                        type="text"
                        name="payment_terms"
                        defaultValue={customer.payment_terms ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">Incoterm</label>
                    <input
                        type="text"
                        name="incoterm"
                        defaultValue={customer.incoterm ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">信用评级</label>
                    <input
                        type="text"
                        name="credit_rating"
                        defaultValue={customer.credit_rating ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                <div>
                    <label className="block text-sm font-medium mb-1">备注</label>
                    <textarea
                        name="notes"
                        rows={3}
                        defaultValue={customer.notes ?? ''}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

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
        </>
    )
}
