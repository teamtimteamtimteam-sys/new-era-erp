// app/operation/weighbridge/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// MES-2(2026-10-06,MES-0 Q19 · Q53;MES-2 Step 0 Q2 · Q16 · Q17 · Q22,Tim)· 地磅单
// ════════════════════════════════════════════════════════════════════════════
// 【这一页是什么】每一张地磅单:一辆车进出地磅的两磅。进厂(inbound)第一磅是毛重,出厂(outbound)第一磅是皮重;
//   第二磅完成它,净重 = 毛重 − 皮重。分出去的份(收货单 / 发货行)之和对着净重显示,差多少就说多少,从不强迫相等。
//   毛重、皮重、净重、状态都是【读的时候算】的(weighbridge_ticket_weights:更正读最新的那一行)。
// 【开一张单】这里手工录第一磅(同一支转换器、一步确认);地磅接上网关之后,第一磅从确认队列里选"开一张地磅单"。
// 【门】requireFunction(FN.weighbridge) = module.inbound.view 或 module.logistics.view(Q22,与照片桶同一道门);
//   录入要 action.confirm_capture(看得见、按不动)。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { ListPage } from '@/app/components/ui/list-page'
import { formatAuditStamp } from '@/lib/dates'
import CellsTable, { type CellRow } from '@/app/operation/equipment/CellsTable'
import { ManualWeighingForm } from '@/app/operation/capture/CaptureControls'
import { INSTRUMENT_KINDS, type Option } from '@/app/operation/capture/captureFields'

type Ticket = {
    ticket_id: string; code: string; direction: string; vehicle_reg: string; status: string; created_at: string
    gross_kg: number | null; tare_kg: number | null; net_kg: number | null; shared_kg: number; difference_kg: number | null
}

export default async function WeighbridgePage() {
    const denied = await requireFunction(FN.weighbridge)
    if (denied) return denied

    const t = await getTranslations()
    const supabase = await createClient()
    const canConfirm = await can('action.confirm_capture')
    const [tRes, devRes] = await Promise.all([
        supabase.from('weighbridge_ticket_weights')
            .select('ticket_id, code, direction, vehicle_reg, status, created_at, gross_kg, tare_kg, net_kg, shared_kg, difference_kg')
            .order('created_at', { ascending: false }).limit(200),
        supabase.from('devices').select('id, code, name, kind, retired_at').order('code'),
    ])
    const tickets = mustRows(tRes, 'weighbridge_ticket_weights') as Ticket[]
    // 仪器的标签:读设备要 module.processing.view;只持收货 / 物流码的人读到零行 —— 那时表单只剩"不选仪器"
    const instruments: Option[] = (mustRows(devRes, 'devices') as { id: string; code: string; name: string; kind: string; retired_at: string | null }[])
        .filter((d) => !d.retired_at && (INSTRUMENT_KINDS as readonly string[]).includes(d.kind))
        .sort((a, b) => (a.kind === 'weighbridge' ? 0 : 1) - (b.kind === 'weighbridge' ? 0 : 1))
        .map((d) => ({ id: d.id, label: `${d.code} — ${d.name}` }))
    const kg = (n: number | null) => (n == null ? '—' : t('capture.kg', { n: String(n) }))

    const rows: CellRow[] = tickets.map((x) => ({
        id: x.ticket_id,
        cells: {
            code: <Link href={`/operation/weighbridge/${x.ticket_id}`} className="app-link hover:underline">{x.code}</Link>,
            vehicle: x.vehicle_reg,
            direction: t('weighbridge.direction.' + x.direction),
            status: <span data-ticket-status={x.status}>{t('weighbridge.status.' + x.status)}</span>,
            gross: kg(x.gross_kg),
            tare: kg(x.tare_kg),
            net: <span className="font-medium">{kg(x.net_kg)}</span>,
            shared: x.net_kg == null ? '—' : (
                <span>{kg(x.shared_kg)}{Number(x.difference_kg) !== 0 && x.difference_kg != null &&
                    <span className="block text-xs text-amber-700">{t('weighbridge.difference', { kg: String(x.difference_kg) })}</span>}</span>
            ),
            created: formatAuditStamp(x.created_at),
        },
    }))

    return (
        <ListPage title={t('weighbridge.title')} intro={t('weighbridge.intro')} maxWidth="max-w-6xl" state={{ kind: 'ok' }}>
            <section className="mb-8">
                <CellsTable
                    columns={[
                        { key: 'code', header: t('weighbridge.colCode'), priority: true },
                        { key: 'vehicle', header: t('weighbridge.colVehicle'), priority: true },
                        { key: 'direction', header: t('weighbridge.colDirection') },
                        { key: 'status', header: t('weighbridge.colStatus'), priority: true },
                        { key: 'gross', header: t('weighbridge.colGross'), align: 'right' },
                        { key: 'tare', header: t('weighbridge.colTare'), align: 'right' },
                        { key: 'net', header: t('weighbridge.colNet'), align: 'right', priority: true },
                        { key: 'shared', header: t('weighbridge.colShared'), align: 'right' },
                        { key: 'created', header: t('weighbridge.colCreated') },
                    ]}
                    rows={rows}
                    empty={t('weighbridge.empty')}
                />
            </section>
            <section className="mb-8">
                <h2 className="mb-2">{t('weighbridge.openTitle')}</h2>
                <p className="mb-2 text-xs text-[color:var(--brand-muted-text)]">{t('weighbridge.openHint')}</p>
                <ManualWeighingForm instruments={instruments} openTickets={[]} canConfirm={canConfirm} fixedSubject={{ kind: 'new' }}
                                    submitLabel={t('weighbridge.openSubmit')} />
            </section>
            <p className="text-sm"><Link href="/operation/capture" className="app-link hover:underline">{t('capture.title')}</Link></p>
        </ListPage>
    )
}
