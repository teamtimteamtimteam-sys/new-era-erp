'use client'

import Link from 'next/link'
// 现场收货(移动端一步式)。cut 4c:选定供应商后,若其有可收货的采购单,追加
// 可选的采购单/行两个下拉 —— 选行预填物料与数量,但【数量始终归过磅的人】,
// 预填只是省几次按键。没有采购单的供应商,页面与从前一字不差。
import { useActionState, useState } from 'react'
import { createFieldReceipt, type ReceiveState } from './actions'
import { useLocale, useTranslations } from '@/lib/i18n/client'
import SourceReasonFields from '../SourceReasonFields'
import type { SourceReasonOption } from '../sourceReasonQuery'
import LocationPicker, { type LocationChoice } from '@/app/components/inventory/LocationPicker'
import IntakeConditionFormSection, { type MaterialAxis } from '../IntakeConditionFormSection'
import type { SafetyState, Certainty } from '../IntakeConditionFields'

const initialState: ReceiveState = {}

type Supplier = { id: string; code: string; legal_name: string }
type Material = { id: string; code: string; name: string }

// supplier_receiving_blocked 的行:该供应商今天收货会被触发器拒(CMP-2)
export type BlockedSupplier = {
    supplier_id: string
    supplier_code: string
    cert_type_code: string
    name_en: string
    name_zh: string
    valid_until: string
}

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
    locations,
    suppliers,
    materials,
    poLines,
    blockedSuppliers,
    safetyStates,
    certainties,
    materialAxes,
    sourceReasons,
}: {
    // IOD-1b:收货库位的可选清单(在用库位),由页面取好传进来
    locations: LocationChoice[]
    suppliers: Supplier[]
    materials: Material[]
    poLines: PoLineOption[]
    blockedSuppliers: BlockedSupplier[]
    // PROC-2c:门口就问的两条轴 —— 现场收货这条路与 /inbound/new 用【同一块控件】
    safetyStates: SafetyState[]
    certainties: Certainty[]
    materialAxes: Record<string, MaterialAxis>
    // RECV-SOURCE-1:无单收货的理由字典(R1:采购行或理由,永不两者皆无)
    sourceReasons: SourceReasonOption[]
}) {
    const t = useTranslations()
    const locale = useLocale()
    const [state, formAction, isPending] = useActionState(createFieldReceipt, initialState)

    const [arrivalDate, setArrivalDate] = useState(todayIsoLocal())

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

    // CMP-2:选中的供应商若会被证书拦截,禁钮并在按钮旁点名证书与过期日 ——
    // 灰而不语的钮,操作员分不清是系统拦截还是自己漏填。触发器仍是独立的那道。
    const blocked = blockedSuppliers.find((b) => b.supplier_id === supplierId)

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
            {/* IOD-1b:收货库位(可选)。默认「未指定 —— 之后用转移指定」 */}
            <LocationPicker locations={locations} />
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
                {/* LOG-1b:空名单不画空下拉 —— 说出它是哪一种空(货代那一侧另有一句)。 */}
                {suppliers.length === 0 ? (
                    <p className="text-sm text-amber-900 bg-amber-50 border border-amber-300 rounded px-3 py-2 max-w-xl">
                        {t('suppliers.pickerEmptyGoods')}
                    </p>
                ) : (
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
                )}
                {state.fieldErrors?.supplier_id && <p className={errCls}>{state.fieldErrors.supplier_id}</p>}
                {/* SUP-TYPE-1b:只列供货的供应商 —— 空的时候【说出为什么】,
                    而不是留一个空下拉配一个按不动的按钮(PAYEE-1a 从报销页
                    删掉的正是那个形状)。 */}
                {suppliers.length === 0 && (
                    <p className="text-xs text-amber-700 mt-1">
                        {t('suppliers.noGoodsSuppliers')}{' '}
                        <Link href="/suppliers" className="underline">
                            {t('suppliers.noGoodsSuppliersLink')}
                        </Link>
                    </p>
                )}
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

            {/* RECV-SOURCE-1:来源 —— 没挂采购行时理由必填(R1);other 要说明(R3)。
                库里的 guard_receipt_source_stated 是真正的闸,这里只是提前说出答案。 */}
            <SourceReasonFields
                reasons={sourceReasons}
                hasPoLine={Boolean(poId && lineId)}
                fieldError={state.fieldErrors?.source_reason_code}
            />

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

            {/* GRN-1b:申报量【可选】。供应商说要来多少,与上面磅秤说的多少是两回事。
                【绝不从采购行预填】—— 上面那个数量框预填 remaining_qty 是便利
                (过磅的人必然会照磅改),申报量预填则是【替供应商说了话】:
                它会让"申报与实收一致"这句话在没有任何供应商文件的情况下成立,
                而那正是这一列存在要回答的问题。空着 = 没记录过,是一个具名状态,
                不是 0(action 传 undefined,库里落 NULL)。 */}
            <div>
                <label className={labelCls}>{t('receive.declaredQty')}</label>
                <div className="flex items-stretch gap-2">
                    <input
                        type="number"
                        name="declared_qty"
                        step="any"
                        min="0"
                        inputMode="decimal"
                        placeholder={t('receive.declaredQtyPlaceholder')}
                        className={fieldCls}
                    />
                    <span className="flex items-center px-3 text-base text-gray-600 bg-gray-100 border border-gray-300 rounded">
                        kg
                    </span>
                </div>
                <p className="text-xs text-gray-500 mt-1">{t('receive.declaredQtyHint')}</p>
                {state.fieldErrors?.declared_qty && <p className={errCls}>{state.fieldErrors.declared_qty}</p>}
            </div>

            {/* 到货日期 —— 【必填】。库存流水的 business_date 抄的就是它(FIN-32)。
                预填今天是【便利】不是默认值:它是受控值,清空就提交不了 ——
                与"服务端偷偷补一个 CURRENT_DATE"是两回事,后者会奖励留空。 */}
            <div>
                <label className={labelCls}>
                    {t('receive.arrivalDate')} <span className="text-red-600">*</span>
                </label>
                <input
                    type="date"
                    name="arrival_date"
                    value={arrivalDate}
                    onChange={(e) => setArrivalDate(e.target.value)}
                    required
                    className={fieldCls}
                />
            </div>

            {/* PROC-2c:到货状态 —— 现场收货的人正站在货前面,这是【他能回答而
                后面的人答不了】的一刻。适不适用由种类决定,判断只有一份。 */}
            <IntakeConditionFormSection
                states={safetyStates} certainties={certainties}
                materialAxes={materialAxes} materialId={materialId} locale={locale}
            />

            {/* 备注 */}
            <div>
                <label className={labelCls}>{t('receive.notes')}</label>
                <textarea name="notes" rows={2} className="w-full border border-gray-300 rounded px-3 py-3 text-base" />
            </div>

            {/* 提交 —— 禁用必须说出为什么(CMP-2):每个禁钮条件都有紧邻的一行字。 */}
            {blocked && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded text-sm">
                    {t('inbound.form.blockedCertExpired', {
                        supplier: blocked.supplier_code,
                        cert: locale === 'zh' ? blocked.name_zh : blocked.name_en,
                        date: blocked.valid_until,
                    })}
                </div>
            )}
            {!blocked && !arrivalDate && (
                <p className="text-sm text-amber-700">{t('inbound.form.blockedArrivalDate')}</p>
            )}
            <button
                type="submit"
                disabled={isPending || !arrivalDate || !!blocked}
                className="w-full bg-blue-600 text-white text-base font-medium rounded px-4 py-3 min-h-[48px] hover:bg-blue-700 disabled:bg-gray-400"
            >
                {isPending ? t('receive.submitting') : t('receive.submit')}
            </button>
        </form>
    )
}
