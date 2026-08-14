'use client'

// SO-3b:发货控件。
//
// 【发货日必填,永不默认】物理事件日,而且它决定收入落进哪个会计期间 ——
// 提交钮在日期空着时禁用【且】服务端按名独立拒(SHIP_DATE_REQUIRED)。
// UI 的 required 只是第三层,不是保护(AGENTS.md 的日期规矩)。
//
// 【后果写在按钮旁边,而且它是【不可撤】的那一种】货离开台账、负债换成收入、
// 那张发票从此作废不了。更正只能走贷项凭证 —— 而那个概念还不存在。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { shipOrderLine } from '../actions'

export type ShipOption = { reservationId: string; label: string; qty: number }

export default function ShipControl({
    orderId,
    options,
    unit,
}: {
    orderId: string
    options: ShipOption[]
    unit: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [pick, setPick] = useState('')
    const [qty, setQty] = useState('')
    const [shipDate, setShipDate] = useState('')

    const chosen = options.find((o) => o.reservationId === pick) ?? null
    const qtyN = Number(qty)
    // 【数量留空 = 整条预留】—— 不是 0。与释放那一处同一条约定。
    const qtyBad = qty.trim() !== '' && (Number.isNaN(qtyN) || qtyN <= 0 || (chosen != null && qtyN > chosen.qty))

    const blocked =
        !chosen ? t('sales.ship.pickReservation')
        : shipDate.trim() === '' ? t('sales.ship.dateRequired')
        : qtyBad ? t('sales.ship.overReservation', { have: String(chosen.qty) })
        : null

    function go() {
        if (!chosen) return
        setError('')
        startTransition(async () => {
            const res = await shipOrderLine(orderId, chosen.reservationId, qty, shipDate)
            if (res.error) setError(res.error)
            else { setPick(''); setQty(''); setShipDate(''); router.refresh() }
        })
    }

    return (
        <div className="mt-2 border-t border-gray-200 pt-2">
            {error && <p className="text-sm text-red-600 mb-2">{error}</p>}
            <div className="flex flex-wrap items-end gap-2">
                <div className="min-w-[18rem]">
                    <label className="block text-xs text-gray-600 mb-1">{t('sales.ship.reservationLabel')}</label>
                    <select value={pick} onChange={(e) => setPick(e.target.value)}
                            className="w-full border border-gray-300 px-2 py-1 rounded text-sm">
                        <option value="">{t('sales.ship.pickReservation')}</option>
                        {options.map((o) => (
                            <option key={o.reservationId} value={o.reservationId}>{o.label}</option>
                        ))}
                    </select>
                </div>
                <div className="w-36">
                    <label className="block text-xs text-gray-600 mb-1">
                        {t('sales.ship.qtyLabel', { unit })}
                    </label>
                    <input type="number" step="any" min="0" value={qty}
                           onChange={(e) => setQty(e.target.value)}
                           placeholder={chosen ? String(chosen.qty) : ''}
                           className="w-full border border-gray-300 px-2 py-1 rounded text-sm" />
                </div>
                <div>
                    <label className="block text-xs text-gray-600 mb-1">{t('sales.ship.shipDate')}</label>
                    <input type="date" value={shipDate} onChange={(e) => setShipDate(e.target.value)}
                           className="border border-gray-300 px-2 py-1 rounded text-sm" />
                </div>
                <button type="button" onClick={go} disabled={isPending || blocked !== null}
                        className="border border-gray-400 px-3 py-1 rounded text-sm hover:bg-gray-50 disabled:opacity-50">
                    {isPending ? t('common.saving') : t('sales.ship.action')}
                </button>
            </div>
            <p className="text-xs text-gray-500 mt-1">{blocked ?? t('sales.ship.consequence')}</p>
        </div>
    )
}
