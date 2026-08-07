'use client'

// 新建进料批次。cut 4c:供应商之后可选【关联采购单】—— 选定供应商后列出其可收货
// 的采购单(po_receivable_lines),再选行,物料与数量按行的剩余量预填(都仍可改 ——
// 实收和下单本来就会有出入)。留空 = 与从前完全一样的临时采购路径。
import { useActionState, useState } from 'react'
import Link from 'next/link'
import { createInbound, type CreateInboundState } from './actions'
import { UNIT_OPTIONS } from '../../materials/options'
import { STAGE_OPTIONS } from '../options'
import { useTranslations } from '@/lib/i18n/client'

const initialState: CreateInboundState = {}

type MaterialOption = { id: string; code: string; name: string }
type SupplierOption = { id: string; code: string; legal_name: string }

// po_receivable_lines 的行(全量下发,客户端按供应商过滤 —— 同收付款表单的做法)
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

export default function NewInboundForm({
    materials,
    suppliers,
    poLines,
    initialPoId = '',
}: {
    materials: MaterialOption[]
    suppliers: SupplierOption[]
    poLines: PoLineOption[]
    initialPoId?: string
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(
        createInbound,
        initialState
    )

    // ?po= 预选(采购单详情"按此单收货"入口):供应商随之带出
    const initialPo = initialPoId ? poLines.find((l) => l.po_id === initialPoId) : undefined
    const [arrivalDate, setArrivalDate] = useState('')
    const [supplierId, setSupplierId] = useState(initialPo?.supplier_id ?? '')
    const [poId, setPoId] = useState(initialPo ? initialPoId : '')
    const [lineId, setLineId] = useState('')
    const [materialId, setMaterialId] = useState('')
    const [quantity, setQuantity] = useState('')

    const supplierPoLines = poLines.filter((l) => l.supplier_id === supplierId)
    // 该供应商的可收货采购单(按 po 去重,保持 view 的顺序)
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

    function onSupplierChange(id: string) {
        setSupplierId(id)
        setPoId('')
        setLineId('')
    }
    function onPoChange(id: string) {
        setPoId(id)
        setLineId('')
    }
    function onLineChange(id: string) {
        setLineId(id)
        const line = poLineOptions.find((l) => l.line_id === id)
        if (line) {
            // 预填物料与剩余量 —— 都仍可改(过磅数是实数,下单数只是约定)
            setMaterialId(line.material_id)
            setQuantity(String(line.remaining_qty))
        }
    }

    return (
        <div className="p-8 max-w-2xl">
            <div className="mb-6">
                <Link
                    href="/inbound"
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-6">{t('inbound.newTitle')}</h1>

            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            <form action={formAction} className="space-y-4">
                {/* 供应商(必填)—— 排在物料前:关联采购单要先知道是谁的单 */}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('inbound.form.supplier')} <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="supplier_id"
                        required
                        value={supplierId}
                        onChange={(e) => onSupplierChange(e.target.value)}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="" disabled>{t('inbound.form.selectSupplier')}</option>
                        {suppliers.map((s) => (
                            <option key={s.id} value={s.id}>
                                {s.code} - {s.legal_name}
                            </option>
                        ))}
                    </select>
                    {state.fieldErrors?.supplier_id && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.supplier_id}
                        </p>
                    )}
                    {suppliers.length === 0 && (
                        <p className="text-xs text-amber-600 mt-1">
                            {t('inbound.form.noSuppliersHelper')}
                            <Link href="/suppliers/new" className="underline">
                                {t('inbound.form.noSuppliersLink')}
                            </Link>
                            {t('inbound.form.noSuppliersHelperPost')}
                        </p>
                    )}
                </div>

                {/* 关联采购单(可选;该供应商没有可收货的单时不出现)*/}
                {supplierPos.length > 0 && (
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('inbound.againstPo')}</label>
                        <select
                            value={poId}
                            onChange={(e) => onPoChange(e.target.value)}
                            className="w-full border border-gray-300 px-3 py-2 rounded"
                        >
                            <option value="">—</option>
                            {supplierPos.map((p) => (
                                <option key={p.po_id} value={p.po_id}>
                                    {p.po_code} · {p.order_date}
                                </option>
                            ))}
                        </select>
                        <p className="text-xs text-gray-500 mt-1">{t('inbound.againstPoHint')}</p>
                        {poId && (
                            <select
                                value={lineId}
                                onChange={(e) => onLineChange(e.target.value)}
                                className="w-full border border-gray-300 px-3 py-2 rounded mt-2"
                            >
                                <option value="" disabled>{t('inbound.selectPoLine')}</option>
                                {poLineOptions.map((l) => (
                                    <option key={l.line_id} value={l.line_id}>
                                        #{l.line_no} {l.material_name} · {t('inbound.poLineRemaining', { qty: l.remaining_qty, unit: l.unit })}
                                    </option>
                                ))}
                            </select>
                        )}
                        {/* 只有选了行才携带关联(单据与行必须成对,不允许只挂单不挂行的半吊子)*/}
                        {poId && lineId && (
                            <>
                                <input type="hidden" name="purchase_order_id" value={poId} />
                                <input type="hidden" name="purchase_order_line_id" value={lineId} />
                            </>
                        )}
                    </div>
                )}

                {/* 物料(必填)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('inbound.form.material')} <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="material_id"
                        required
                        value={materialId}
                        onChange={(e) => setMaterialId(e.target.value)}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="" disabled>{t('inbound.form.selectMaterial')}</option>
                        {materials.map((m) => (
                            <option key={m.id} value={m.id}>
                                {m.code} - {m.name}
                            </option>
                        ))}
                    </select>
                    {state.fieldErrors?.material_id && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.material_id}
                        </p>
                    )}
                    {materials.length === 0 && (
                        <p className="text-xs text-amber-600 mt-1">
                            {t('inbound.form.noMaterialsHelper')}
                            <Link href="/materials/new" className="underline">
                                {t('inbound.form.noMaterialsLink')}
                            </Link>
                            {t('inbound.form.noMaterialsHelperPost')}
                        </p>
                    )}
                </div>

                {/* 数量(必填)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('inbound.form.quantity')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="number"
                        name="quantity"
                        required
                        step="any"
                        min="0"
                        value={quantity}
                        onChange={(e) => setQuantity(e.target.value)}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                    {state.fieldErrors?.quantity && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.quantity}
                        </p>
                    )}
                </div>

                {/* 单位 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('inbound.form.unit')}</label>
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

                {/* 到货日期 —— 【必填】。它是收货人当场就知道的事实,而库存流水的
                    business_date 直接抄它(FIN-32):留空,这条流水就永远说不出
                    货是哪天到的。守卫成对(AGENTS.md):这里控制提交按钮,
                    服务端 action 另有一道独立的拒绝,绕过界面也进不来。 */}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('inbound.form.arrivalDate')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="date"
                        name="arrival_date"
                        value={arrivalDate}
                        onChange={(e) => setArrivalDate(e.target.value)}
                        required
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>

                {/* 阶段 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('inbound.form.stage')}</label>
                    <select
                        name="stage"
                        defaultValue="待加工"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        {STAGE_OPTIONS.map((s) => (
                            <option key={s.value} value={s.value}>
                                {t(s.labelKey)}
                            </option>
                        ))}
                    </select>
                </div>

                {/* 单价 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('inbound.form.unitPrice')}</label>
                    <input
                        type="number"
                        name="unit_price"
                        step="any"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                    {state.fieldErrors?.unit_price && (
                        <p className="text-red-600 text-xs mt-1">
                            {state.fieldErrors.unit_price}
                        </p>
                    )}
                </div>

                {/* 备注 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('inbound.form.notes')}</label>
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
                        disabled={isPending || !arrivalDate}
                        className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                    >
                        {isPending ? t('common.saving') : t('common.save')}
                    </button>
                    <Link
                        href="/inbound"
                        className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                    >
                        {t('common.cancel')}
                    </Link>
                </div>
            </form>
        </div>
    )
}
