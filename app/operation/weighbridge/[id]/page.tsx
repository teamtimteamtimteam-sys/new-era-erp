// app/operation/weighbridge/[id]/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// MES-2(2026-10-06,MES-0 Q19–Q21;MES-2 Step 0 Q16–Q22 · Q28 · Q33,Tim)· 一张地磅单
// ════════════════════════════════════════════════════════════════════════════
// 【毛重 · 皮重 · 净重】指着本单的两磅(更正过的划掉、读最新的那一行);每一磅的仪器与它在读数那一天在不在校准期内
//   (只标 —— 开关开着时,挂着这张单的收货单定价与销毁证书才会被拒,Q26 · Q28)。
// 【分出去的份】每一份一行(收货单或发货行,明写公斤数),之和对着净重,差多少照直显示 —— 从不强迫相等(MES-0 Q19)。
//   收货单的数量与份不同时,建单那一刻写下的理由在这里看得见(Q19)。一张读者看不见的收货单 / 发货行,标签说「受限」,不留白
//   (AGENTS.md 决定 3:一个空白的名字读起来像缺数据)。
// 【开着的单】录第二磅(手工,一步确认);网关送来的第二磅从确认队列里选"完成一张开着的单"。
// 【照片】私有桶 capture-photos(读:收货或物流查看码);传与撤要 action.confirm_capture。
// 【门】requireFunction(FN.weighbridge);分给收货单 action.receive_goods、分给发货行 action.ship_goods、作废 action.confirm_capture。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
import { formatAuditStamp } from '@/lib/dates'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import CellsTable, { type CellRow } from '@/app/operation/equipment/CellsTable'
import { ManualWeighingForm } from '@/app/operation/capture/CaptureControls'
import { INSTRUMENT_KINDS, type Option } from '@/app/operation/capture/captureFields'
import { ShareForm, VoidTicket, PhotoPanel } from './TicketControls'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

type Ticket = {
    ticket_id: string; code: string; direction: string; vehicle_reg: string; notes: string | null; status: string
    created_at: string; completed_at: string | null; voided_at: string | null; void_reason: string | null
    gross_kg: number | null; tare_kg: number | null; net_kg: number | null; shared_kg: number; difference_kg: number | null
    share_count: number; deleted_receipt_shares: number
}
type W = { weighing_id: string; role: string; weight_kg: number; source: string; device_code: string | null; captured_at: string; is_current: boolean; status: string }
type Share = { id: string; inbound_batch_id: string | null; shipment_line_id: string | null; kg: number; receipt_quantity_reason: string | null; created_at: string }

export default async function TicketPage({ params, searchParams }: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ trail?: string | string[] }>
}) {
    const denied = await requireFunction(FN.weighbridge)
    if (denied) return denied
    const { id } = await params
    if (!UUID.test(id)) notFound()

    const t = await getTranslations()
    const supabase = await createClient()
    const [canConfirm, canReceive, canShip] = await Promise.all([
        can('action.confirm_capture'), can('action.receive_goods'), can('action.ship_goods'),
    ])
    const tk = mustOne(await supabase.from('weighbridge_ticket_weights')
        .select('ticket_id, code, direction, vehicle_reg, notes, status, created_at, completed_at, voided_at, void_reason, gross_kg, tare_kg, net_kg, shared_kg, difference_kg, share_count, deleted_receipt_shares')
        .eq('ticket_id', id).maybeSingle(), 'weighbridge_ticket_weights') as Ticket | null
    if (!tk) notFound()

    const [wRes, sRes, pRes, devRes] = await Promise.all([
        supabase.from('weighing_calibration').select('weighing_id, role, weight_kg, source, device_code, captured_at, is_current, status')
            .eq('ticket_id', id).order('captured_at'),
        supabase.from('weighbridge_ticket_shares').select('id, inbound_batch_id, shipment_line_id, kg, receipt_quantity_reason, created_at')
            .eq('ticket_id', id).order('created_at'),
        supabase.from('weighbridge_ticket_photos').select('id, file_path, file_name, uploaded_at, withdrawn_at, withdraw_reason')
            .eq('ticket_id', id).order('uploaded_at'),
        supabase.from('devices').select('id, code, name, kind, retired_at').order('code'),
    ])
    const weighings = mustRows(wRes, 'weighing_calibration') as W[]
    const shares = mustRows(sRes, 'weighbridge_ticket_shares') as Share[]
    const photos = mustRows(pRes, 'weighbridge_ticket_photos') as { id: string; file_path: string; file_name: string; uploaded_at: string; withdrawn_at: string | null; withdraw_reason: string | null }[]
    const instruments: Option[] = (mustRows(devRes, 'devices') as { id: string; code: string; name: string; kind: string; retired_at: string | null }[])
        .filter((d) => !d.retired_at && (INSTRUMENT_KINDS as readonly string[]).includes(d.kind))
        .map((d) => ({ id: d.id, label: `${d.code} — ${d.name}` }))

    // 份的标签:收货单编号(module.inbound.view 读得到)/ 发货单编号(module.sales.view 或 action.ship_goods 读得到);读不到的说「受限」
    const batchIds = shares.map((s) => s.inbound_batch_id).filter((x): x is string => !!x)
    const lineIds = shares.map((s) => s.shipment_line_id).filter((x): x is string => !!x)
    const batchLabel = new Map<string, { code: string; quantity: number; deleted: boolean }>()
    if (batchIds.length > 0) {
        // RLS 挡下的是【行】(零行,不是错误)—— 读不到的那几份落到「受限」;一次真的失败照样抛
        ;(mustRows(await supabase.from('inbound_batches_masked').select('id, code, quantity, deleted_at').in('id', batchIds), 'inbound_batches_masked') as
            { id: string; code: string; quantity: number; deleted_at: string | null }[])
            .forEach((b) => batchLabel.set(b.id, { code: b.code, quantity: Number(b.quantity), deleted: !!b.deleted_at }))
    }
    const lineLabel = new Map<string, string>()
    if (lineIds.length > 0) {
        ;(mustRows(await supabase.from('shipment_lines').select('id, qty, shipments(code)').in('id', lineIds), 'shipment_lines') as unknown as
            { id: string; qty: number; shipments: { code: string } | null }[])
            .forEach((l) => lineLabel.set(l.id, `${l.shipments?.code ?? '—'} · ${t('capture.kg', { n: String(l.qty) })}`))
    }

    // 分份的去处:进厂单 → 最近的、还没挂这张单的收货单;出厂单 → 最近的发货行
    let targets: Option[] = []
    if (tk.status === 'complete' && tk.direction === 'inbound' && canReceive) {
        const r = mustRows(await supabase.from('inbound_batches_masked').select('id, code, quantity')
            .is('deleted_at', null).order('created_at', { ascending: false }).limit(50), 'inbound_batches_masked') as { id: string; code: string; quantity: number }[]
        targets = r.filter((b) => !batchIds.includes(b.id)).map((b) => ({ id: b.id, label: `${b.code} · ${t('capture.kg', { n: String(b.quantity) })}` }))
    } else if (tk.status === 'complete' && tk.direction === 'outbound' && canShip) {
        const r = mustRows(await supabase.from('shipment_lines').select('id, qty, shipments(code)')
            .order('created_at', { ascending: false }).limit(50), 'shipment_lines') as unknown as { id: string; qty: number; shipments: { code: string } | null }[]
        targets = r.filter((l) => !lineIds.includes(l.id)).map((l) => ({ id: l.id, label: `${l.shipments?.code ?? '—'} · ${t('capture.kg', { n: String(l.qty) })}` }))
    }

    const kg = (n: number | null) => (n == null ? '—' : t('capture.kg', { n: String(n) }))
    const weighingRows: CellRow[] = weighings.map((w) => ({
        id: w.weighing_id,
        cells: {
            role: t('weighing.role.' + w.role),
            weight: <span className={w.is_current ? 'font-medium' : 'line-through'}>{kg(w.weight_kg)}</span>,
            at: formatAuditStamp(w.captured_at),
            instrument: (
                <span data-calibration-status={w.status}>
                    {w.device_code ?? '—'}
                    <span className={`block text-xs ${w.status === 'in_calibration' ? 'text-[color:var(--brand-muted-text)]' : 'text-amber-700'}`}>
                        {t('calibration.status.' + w.status)}
                    </span>
                </span>
            ),
            source: t('capture.source.' + w.source),
        },
    }))
    const shareRows: CellRow[] = shares.map((s) => {
        const b = s.inbound_batch_id ? batchLabel.get(s.inbound_batch_id) : null
        const target = s.inbound_batch_id
            ? (b ? <Link href={`/inbound/${s.inbound_batch_id}/edit`} className={`app-link hover:underline ${b.deleted ? 'line-through' : ''}`}>{b.code}</Link> : t('common.restricted'))
            : (s.shipment_line_id && lineLabel.get(s.shipment_line_id)) || t('common.restricted')
        return {
            id: s.id,
            cells: {
                target,
                kind: s.inbound_batch_id ? t('weighbridge.shareKind.receipt') : t('weighbridge.shareKind.line'),
                kg: kg(s.kg),
                quantity: b ? (
                    <span>{kg(b.quantity)}
                        {s.receipt_quantity_reason && <span className="block text-xs text-[color:var(--brand-muted-text)]">{s.receipt_quantity_reason}</span>}
                        {b.deleted && <span className="block text-xs text-amber-700">{t('weighbridge.receiptDeleted')}</span>}
                    </span>
                ) : '—',
                at: formatAuditStamp(s.created_at),
            },
        }
    })
    const remaining = tk.net_kg != null ? Math.max(0, Number(tk.difference_kg ?? 0)) : 0

    return (
        <ListPage
            breadcrumb={<Link href="/operation/weighbridge" className="app-link hover:underline text-sm">← {t('weighbridge.title')}</Link>}
            title={`${tk.code} · ${tk.vehicle_reg}`}
            maxWidth="max-w-6xl"
            state={{ kind: 'ok' }}
        >
            <RecordHeader
                fields={[
                    { label: t('weighbridge.colCode'), value: tk.code, mono: true },
                    { label: t('weighbridge.colStatus'), value: <span data-ticket-status={tk.status}>{t('weighbridge.status.' + tk.status)}</span> },
                    { label: t('weighbridge.colDirection'), value: t('weighbridge.direction.' + tk.direction) },
                    { label: t('weighbridge.colVehicle'), value: tk.vehicle_reg },
                    { label: t('weighbridge.colGross'), value: kg(tk.gross_kg) },
                    { label: t('weighbridge.colTare'), value: kg(tk.tare_kg) },
                    { label: t('weighbridge.colNet'), value: <span data-ticket-net={tk.net_kg ?? ''}>{kg(tk.net_kg)}</span> },
                    { label: t('weighbridge.colShared'), value: tk.net_kg == null ? '—' : `${kg(tk.shared_kg)} · ${t('weighbridge.difference', { kg: String(tk.difference_kg) })}` },
                    { label: t('weighbridge.colCreated'), value: formatAuditStamp(tk.created_at) },
                    ...(tk.completed_at ? [{ label: t('weighbridge.completedAt'), value: formatAuditStamp(tk.completed_at) }] : []),
                    ...(tk.voided_at ? [{ label: t('weighbridge.status.voided'), value: `${formatAuditStamp(tk.voided_at)} · ${tk.void_reason ?? ''}` }] : []),
                ]}
            />
            {tk.notes && <p className="mb-4 text-sm">{tk.notes}</p>}

            <section className="mt-6">
                <h2 className="mb-2">{t('weighbridge.weighingsTitle')}</h2>
                <CellsTable
                    columns={[
                        { key: 'role', header: t('capture.colSubject'), priority: true },
                        { key: 'weight', header: t('capture.colWeight'), align: 'right', priority: true },
                        { key: 'at', header: t('capture.colWeighedAt') },
                        { key: 'instrument', header: t('capture.colInstrument') },
                        { key: 'source', header: t('capture.colSource') },
                    ]}
                    rows={weighingRows}
                    empty="—"
                />
                {tk.status === 'open' && (
                    <div className="mt-4">
                        <h3 className="mb-2 text-sm font-medium">{tk.direction === 'inbound' ? t('weighbridge.addTare') : t('weighbridge.addGross')}</h3>
                        <ManualWeighingForm instruments={instruments} openTickets={[]} canConfirm={canConfirm}
                                            fixedSubject={{ kind: 'ticket', ticketId: id }} submitLabel={t('weighbridge.completeSubmit')} />
                    </div>
                )}
                <p className="mt-2 text-sm"><Link href="/operation/capture" className="app-link hover:underline">{t('capture.title')}</Link></p>
            </section>

            <section className="mt-8">
                <h2 className="mb-2">{t('weighbridge.sharesTitle')}</h2>
                <p className="mb-2 text-xs text-[color:var(--brand-muted-text)]">{t('weighbridge.sharesHint')}</p>
                <CellsTable
                    columns={[
                        { key: 'target', header: t('weighbridge.colTarget'), priority: true },
                        { key: 'kind', header: t('weighbridge.colKind') },
                        { key: 'kg', header: t('weighbridge.shareKg'), align: 'right', priority: true },
                        { key: 'quantity', header: t('weighbridge.colReceiptQty'), align: 'right' },
                        { key: 'at', header: t('weighbridge.colCreated') },
                    ]}
                    rows={shareRows}
                    empty={t('weighbridge.noShares')}
                />
                {tk.deleted_receipt_shares > 0 && <p className="mt-1 text-xs text-amber-700">{t('weighbridge.deletedShares', { n: String(tk.deleted_receipt_shares) })}</p>}
                {tk.status === 'complete' && (
                    <div className="mt-4">
                        <ShareForm ticketId={id} direction={tk.direction} targets={targets} defaultKg={remaining} code={tk.code}
                                   allowed={tk.direction === 'inbound' ? canReceive : canShip} />
                    </div>
                )}
                {tk.status === 'open' && <p className="mt-2 text-xs text-[color:var(--brand-muted-text)]">{t('weighbridge.shareNeedsComplete')}</p>}
            </section>

            <section className="mt-8">
                <h2 className="mb-2">{t('weighbridge.photosTitle')}</h2>
                <PhotoPanel ticketId={id} canUpload={canConfirm} voided={!!tk.voided_at}
                            photos={photos.map((p) => ({ ...p, at: formatAuditStamp(p.uploaded_at) }))} />
            </section>

            {!tk.voided_at && (
                <section className="mt-8">
                    <VoidTicket ticketId={id} code={tk.code} allowed={canConfirm} hasShares={Number(tk.share_count) + Number(tk.deleted_receipt_shares) > 0} />
                </section>
            )}

            <AuditTrail subject="weighbridge_ticket" id={id} show={trailCount((await searchParams).trail)} />
        </ListPage>
    )
}
