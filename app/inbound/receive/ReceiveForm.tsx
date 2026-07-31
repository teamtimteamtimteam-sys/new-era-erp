'use client'

// 现场收货(移动端一步式)。cut 4c:选定供应商后,若其有可收货的采购单,追加
// 可选的采购单/行两个下拉 —— 选行预填物料与数量,但【数量始终归过磅的人】,
// 预填只是省几次按键。没有采购单的供应商,页面与从前一字不差。
import { useActionState, useState } from 'react'
import { createFieldReceipt, type ReceiveState } from './actions'
import { useTranslations } from '@/lib/i18n/client'

const initialState: ReceiveState = {}

type Supplier = { id: string; code: string; legal_name: string }
type Material = { id: string; code: string; name: string }

export type PoLineOption = {
    po_id: string
    po_code: string
    supplier_id: string
    order_date: string
    line_id: string
    line_no: number
    material_id: string
    material_name: string
    remaining_qty: number
    unit: string
}

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
    poLines,
}: {
    suppliers: Supplier[]
    materials: Material[]
    poLines: PoLineOption[]
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(createFieldReceipt, initialState)

    const [supplierId, setSupplierId] = useState('')
    const [poId, setPoId] = useState('')
    const [lineId, setLineId] = useState('')
    const [materialId, setMaterialId] = useState('')
    const [quantity, setQuantity] = useState('')

    const supplierPoLines = poLines.filter((l) => l.supplier_id === supplierId)
    const supplierPos = supplierPoLines.reduce<{ po_id: string; po_code: string; order_date: string }[]>(
        (acc, l) => {
            if (!acc.some((p) => p.po_id === l.po_id)) {
                acc.push({ po_id: l.po_id, po_code: l.po_code, order_date: l.order_date })
            }
            return acc
        },
        []
    )
    const poLineOptions = supplierPoLines.filter((l) => l.po_id === poId)

    function onLineChange(id: string) {
        setLineId(id)
        const line = poLineOptions.find((l) => l.line_id === id)
        if (line) {
            setMaterialId(line.material_id)
            setQuantity(String(line.remaining_qty)) // 预填,但过磅数永远归操作员改
        }
    }

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
                <select
                    name="supplier_id"
                    required
                    value={supplierId}
                    onChange={(e) => {
                        setSupplierId(e.target.value)
                        setPoId('')
                        setLineId('')
                    }}
                    className={fieldCls}
                >
                    <option value="" disabled>{t('receive.supplier')}</option>
                    {suppliers.map((s) => (
                        <option key={s.id} value={s.id}>
                            {s.code} - {s.legal_name}
                        </option>
                    ))}
                </select>
                {state.fieldErrors?.supplier_id && <p className={errCls}>{state.fieldErrors.supplier_id}</p>}
            </div>

            {/* 关联采购单(仅当该供应商有可收货的单;没有则控件数与从前一样少)*/}
            {supplierPos.length > 0 && (
                <div>
                    <label className={labelCls}>{t('inbound.againstPo')}</label>
                    <select
                        value={poId}
                        onChange={(e) => {
                            setPoId(e.target.value)
                            setLineId('')
                        }}
                        className={fieldCls}
                    >
                        <option value="">—</option>
                        {supplierPos.map((p) => (
                            <option key={p.po_id} value={p.po_id}>
                                {p.po_code} · {p.order_date}
                            </option>
                        ))}
                    </select>
                    {poId && (
                        <select
                            value={lineId}
                            onChange={(e) => onLineChange(e.target.value)}
                            className={fieldCls + ' mt-2'}
                        >
                            <option value="" disabled>{t('inbound.selectPoLine')}</option>
                            {poLineOptions.map((l) => (
                                <option key={l.line_id} value={l.line_id}>
                                    #{l.line_no} {l.material_name} · {t('inbound.poLineRemaining', { qty: l.remaining_qty, unit: l.unit })}
                                </option>
                            ))}
                        </select>
                    )}
                    {poId && lineId && (
                        <>
                            <input type="hidden" name="purchase_order_id" value={poId} />
                            <input type="hidden" name="purchase_order_line_id" value={lineId} />
                        </>
                    )}
                </div>
            )}

            {/* 物料 */}
            <div>
                <label className={labelCls}>
                    {t('receive.material')} <span className="text-red-600">*</span>
                </label>
                <select
                    name="material_id"
                    required
                    value={materialId}
                    onChange={(e) => setMaterialId(e.target.value)}
                    className={fieldCls}
                >
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
                        value={quantity}
                        onChange={(e) => setQuantity(e.target.value)}
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
