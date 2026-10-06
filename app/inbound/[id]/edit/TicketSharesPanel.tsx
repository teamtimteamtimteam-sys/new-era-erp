// app/inbound/[id]/edit/TicketSharesPanel.tsx
// MES-2(2026-10-06,MES-0 Q19 · Q21;MES-2 Step 0 Q19 · Q28,Tim):这张收货单挂着的地磅单的份。
//   每一份:哪一张单(链到它)、分给本单多少公斤、建单时数量与份不同的理由;以及那张单【最新】两磅的仪器在读数那一天在不在校准期内
//   —— 只标(Q28)。校准规则开着、而且本单是在那一天及以后建的,定价与销毁证书才会因此被拒(Q26 · Q27);这里说清楚是哪一种。
//   一张单都没挂:规则开着时,这一张的定价与证书会被拒(RECEIPT_READING_NOT_RECORDED)—— 也照直说。
//   服务端组件:读 weighbridge_ticket_shares / weighbridge_tickets(收货或物流查看码)与 weighing_calibration。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'

export default async function TicketSharesPanel({ batchId, quantity, createdAt }: { batchId: string; quantity: number; createdAt: string }) {
    const t = await getTranslations()
    const supabase = await createClient()
    const [shareRes, setRes] = await Promise.all([
        supabase.from('weighbridge_ticket_shares').select('id, ticket_id, kg, receipt_quantity_reason').eq('inbound_batch_id', batchId).order('created_at'),
        supabase.from('ingest_settings').select('require_calibrated_since').maybeSingle(),
    ])
    const shares = mustRows(shareRes, 'weighbridge_ticket_shares') as { id: string; ticket_id: string; kg: number; receipt_quantity_reason: string | null }[]
    // 设置那一行只给持加工查看码的人读;读不到就不说规则开没开(不猜)
    const settings = mustOne(setRes, 'ingest_settings') as { require_calibrated_since: string | null } | null
    const since = settings?.require_calibrated_since ?? null
    // 与 assert_receipt_reading_calibrated 同一个日历:收货单建在新加坡的哪一天
    const createdOn = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Singapore' }).format(new Date(createdAt))
    const ruleApplies = since !== null && createdOn >= since
    const ticketIds = shares.map((s) => s.ticket_id)
    const tickets = new Map<string, string>()
    const readings = new Map<string, { role: string; device_code: string | null; status: string }[]>()
    if (ticketIds.length > 0) {
        ;(mustRows(await supabase.from('weighbridge_tickets').select('id, code').in('id', ticketIds), 'weighbridge_tickets') as { id: string; code: string }[])
            .forEach((x) => tickets.set(x.id, x.code))
        ;(mustRows(await supabase.from('weighing_calibration').select('ticket_id, role, device_code, status').in('ticket_id', ticketIds).eq('is_current', true),
            'weighing_calibration') as { ticket_id: string; role: string; device_code: string | null; status: string }[])
            .forEach((w) => readings.set(w.ticket_id, [...(readings.get(w.ticket_id) ?? []), w]))
    }
    return (
        <section className="mt-6" data-receipt-tickets={shares.length}>
            <h2 className="mb-2">{t('weighbridge.receiptPanelTitle')}</h2>
            {shares.length === 0 && (
                <p className="text-sm text-[color:var(--brand-muted-text)]">
                    {t('weighbridge.receiptNoTicket')}{ruleApplies && <span className="block text-amber-700">{t('weighbridge.receiptRuleNoTicket')}</span>}
                </p>
            )}
            <ul className="space-y-2 text-sm">
                {shares.map((s) => (
                    <li key={s.id}>
                        <Link href={`/operation/weighbridge/${s.ticket_id}`} className="app-link hover:underline">{tickets.get(s.ticket_id) ?? t('common.restricted')}</Link>
                        {' · '}{t('weighbridge.receiptShare', { kg: String(s.kg), qty: String(quantity) })}
                        {s.receipt_quantity_reason && <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('weighbridge.receiptReason', { reason: s.receipt_quantity_reason })}</span>}
                        {(readings.get(s.ticket_id) ?? []).map((r) => (
                            <span key={r.role} className={`block text-xs ${r.status === 'in_calibration' ? 'text-[color:var(--brand-muted-text)]' : 'text-amber-700'}`}
                                  data-calibration-status={r.status}>
                                {t('weighing.role.' + r.role)} · {r.device_code ?? '—'} · {t('calibration.status.' + r.status)}
                            </span>
                        ))}
                    </li>
                ))}
            </ul>
            {settings !== null && (
                <p className="mt-2 text-xs text-[color:var(--brand-muted-text)]">
                    {since === null ? t('calibration.ruleOffHint') : ruleApplies ? t('calibration.ruleAppliesHere', { date: since }) : t('calibration.ruleNotHere', { date: since })}
                </p>
            )}
        </section>
    )
}
