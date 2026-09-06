'use client'

import { useActionState } from 'react'
import { createSupplier, type CreateSupplierState } from '@/app/suppliers/new/actions'
import { Button } from '@/app/components/ui/button'

// LOG-1c:新建货代。
// 【它调的是供应商那条创建路径,不是第二处 insert】—— 货代在库里就是一行 suppliers,
// 只是 counterparty_type 不同。两处各写一份 insert,规矩迟早各自演化(LOG-1a 为
// 账号关联那一处记过同样的账)。这里只用两个隐藏字段把"类型"与"回跳去哪"传过去。

const initial: CreateSupplierState = {}

export default function NewForwarderForm({
    labels,
}: {
    labels: { heading: string; legalName: string; country: string; paymentTerms: string; submit: string }
}) {
    const [state, formAction, pending] = useActionState(createSupplier, initial)
    const field = 'border border-gray-300 px-3 py-2 rounded'

    return (
        <form action={formAction} className="mt-4 rounded border border-gray-200 bg-gray-50 p-4">
            <h2 className="font-medium mb-3">{labels.heading}</h2>
            {state.error && (
                <div className="mb-3 rounded border border-red-400 bg-red-50 px-3 py-2 text-sm text-red-800">{state.error}</div>
            )}
            {/* 【同一条创建路径】:类型钉成 forwarder,回跳到货代名单 */}
            <input type="hidden" name="counterparty_type" value="forwarder" />
            <input type="hidden" name="redirect_to" value="/logistics/forwarders" />
            <div className="flex flex-wrap items-end gap-3">
                <div>
                    <label className="block text-xs font-medium mb-1">{labels.legalName}</label>
                    <input name="legal_name" required className={field} />
                    {state.fieldErrors?.legal_name && (
                        <p className="text-xs text-red-700 mt-1">{state.fieldErrors.legal_name}</p>
                    )}
                </div>
                <div>
                    <label className="block text-xs font-medium mb-1">{labels.country}</label>
                    <input name="country" required maxLength={2} className={`${field} w-20`} />
                    {state.fieldErrors?.country && (
                        <p className="text-xs text-red-700 mt-1">{state.fieldErrors.country}</p>
                    )}
                </div>
                <div>
                    <label className="block text-xs font-medium mb-1">{labels.paymentTerms}</label>
                    <input name="payment_terms" className={field} />
                </div>
                <Button
                    type="submit"
                    disabled={pending}
                    variant="default" size="default"
                >
                    {labels.submit}
                </Button>
            </div>
        </form>
    )
}
