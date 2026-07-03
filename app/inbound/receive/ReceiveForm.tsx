'use client'

import { useActionState } from 'react'
import { createFieldReceipt, type ReceiveState } from './actions'
import { useTranslations } from '@/lib/i18n/client'

const initialState: ReceiveState = {}

type Supplier = { id: string; code: string; legal_name: string }
type Material = { id: string; code: string; name: string }

function todayIsoLocal(): string {
    const d = new Date()
    const yyyy = d.getFullYear()
    const mm = String(d.getMonth() + 1).padStart(2, '0')
    const dd = String(d.getDate()).padStart(2, '0')
    return `${yyyy}-${mm}-${dd}`
}

// 移动端触摸友好:大字号 + 约 48px 高的触控目标。
const fieldCls =
    'w-full border border-gray-300 rounded px-3 py-3 text-base min-h-[48px] bg-white'
const labelCls = 'block text-sm font-medium mb-1'
const errCls = 'text-red-600 text-sm mt-1'

export default function ReceiveForm({
    suppliers,
    materials,
}: {
    suppliers: Supplier[]
    materials: Material[]
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(createFieldReceipt, initialState)

    return (
        <form action={formAction} className="space-y-5">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}

            {/* 供应商 */}
            <div>
                <label className={labelCls}>
                    {t('receive.supplier')} <span className="text-red-600">*</span>
                </label>
                <select name="supplier_id" required defaultValue="" className={fieldCls}>
                    <option value="" disabled>{t('receive.supplier')}</option>
                    {suppliers.map((s) => (
                        <option key={s.id} value={s.id}>
                            {s.code} - {s.legal_name}
                        </option>
                    ))}
                </select>
                {state.fieldErrors?.supplier_id && <p className={errCls}>{state.fieldErrors.supplier_id}</p>}
            </div>

            {/* 物料 */}
            <div>
                <label className={labelCls}>
                    {t('receive.material')} <span className="text-red-600">*</span>
                </label>
                <select name="material_id" required defaultValue="" className={fieldCls}>
                    <option value="" disabled>{t('receive.material')}</option>
                    {materials.map((m) => (
                        <option key={m.id} value={m.id}>
                            {m.code} - {m.name}
                        </option>
                    ))}
                </select>
                {state.fieldErrors?.material_id && <p className={errCls}>{state.fieldErrors.material_id}</p>}
            </div>

            {/* 过磅重量(kg 固定,不作为输入)*/}
            <div>
                <label className={labelCls}>
                    {t('receive.quantity')} <span className="text-red-600">*</span>
                </label>
                <div className="flex items-stretch gap-2">
                    <input
                        type="number"
                        name="quantity"
                        required
                        step="any"
                        min="0"
                        inputMode="decimal"
                        placeholder={t('receive.qtyPlaceholder')}
                        className={fieldCls}
                    />
                    <span className="flex items-center px-3 text-base text-gray-600 bg-gray-100 border border-gray-300 rounded">
                        kg
                    </span>
                </div>
                {state.fieldErrors?.quantity && <p className={errCls}>{state.fieldErrors.quantity}</p>}
            </div>

            {/* 到货日期 */}
            <div>
                <label className={labelCls}>{t('receive.arrivalDate')}</label>
                <input
                    type="date"
                    name="arrival_date"
                    defaultValue={todayIsoLocal()}
                    className={fieldCls}
                />
            </div>

            {/* 备注 */}
            <div>
                <label className={labelCls}>{t('receive.notes')}</label>
                <textarea name="notes" rows={2} className="w-full border border-gray-300 rounded px-3 py-3 text-base" />
            </div>

            {/* 提交 */}
            <button
                type="submit"
                disabled={isPending}
                className="w-full bg-blue-600 text-white text-base font-medium rounded px-4 py-3 min-h-[48px] hover:bg-blue-700 disabled:bg-gray-400"
            >
                {isPending ? t('receive.submitting') : t('receive.submit')}
            </button>
        </form>
    )
}
