'use client'

// app/inbound/TicketShareFields.tsx
// MES-2(2026-10-06,MES-0 Q19 · Q21;MES-2 Step 0 Q19,Tim):收货单【建的那一刻】挂一张地磅单的份 —— 两个收货表单共用。
//   选一张【完成了的进厂单】→ 份默认 = 它还没分出去的那部分 → 数量框【预填成这一份】。人改了数量(数量始终归过磅的人),
//   就要写一句理由;收货单两个都留着:份的公斤数挂在地磅单上,数量与理由在收货单上(理由落在那一份上)。
//   不选 = 与从前一字不差(三个字段都不送)。判据在库里(create_inbound_batch / receive_inbound_batch_against_po):
//   只从完成了的进厂单分、单位是 kg、数量与份不同时理由必填。
import { useTranslations } from '@/lib/i18n/client'

export type TicketOption = { id: string; code: string; vehicle_reg: string; net_kg: number; remaining_kg: number }

export default function TicketShareFields({ tickets, ticketId, setTicketId, shareKg, setShareKg, quantity, setQuantity, reason, setReason,
    fieldCls, labelCls, error }: {
    tickets: TicketOption[]
    ticketId: string; setTicketId: (v: string) => void
    shareKg: string; setShareKg: (v: string) => void
    quantity: string; setQuantity: (v: string) => void
    reason: string; setReason: (v: string) => void
    fieldCls: string; labelCls: string; error?: string
}) {
    const t = useTranslations()
    if (tickets.length === 0) return null
    const differs = ticketId !== '' && shareKg.trim() !== '' && quantity.trim() !== '' && Number(shareKg) !== Number(quantity)
    return (
        <div className="space-y-2" data-receipt-ticket="1">
            <label className={labelCls}>{t('receive.ticket')}</label>
            <select name="ticket_id" value={ticketId} className={fieldCls}
                    onChange={(e) => {
                        const id = e.target.value
                        setTicketId(id)
                        const tk = tickets.find((x) => x.id === id)
                        if (tk) { setShareKg(String(tk.remaining_kg)); setQuantity(String(tk.remaining_kg)) }
                        else { setShareKg('') }
                    }}>
                <option value="">{t('receive.noTicket')}</option>
                {tickets.map((x) => (
                    <option key={x.id} value={x.id}>
                        {t('receive.ticketOption', { code: x.code, vehicle: x.vehicle_reg, net: String(x.net_kg), left: String(x.remaining_kg) })}
                    </option>
                ))}
            </select>
            {ticketId !== '' && (
                <>
                    <label className={labelCls}>{t('receive.ticketShareKg')}</label>
                    <input type="number" name="ticket_share_kg" step="any" min="0" inputMode="decimal" value={shareKg}
                           onChange={(e) => setShareKg(e.target.value)} className={fieldCls} />
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('receive.ticketShareHint')}</p>
                    {differs && (
                        <>
                            <label className={labelCls}>{t('receive.quantityReason')} <span className="text-red-600">*</span></label>
                            <input name="quantity_reason" value={reason} onChange={(e) => setReason(e.target.value)} className={fieldCls}
                                   data-receipt-quantity-reason="1" />
                        </>
                    )}
                </>
            )}
            {error && <p className="text-sm text-red-600">{error}</p>}
        </div>
    )
}
