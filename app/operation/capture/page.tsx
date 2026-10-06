// app/operation/capture/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// MES-2(2026-10-06,规格 §6.3;MES-0 §3.6 · Q10–Q13;MES-2 Step 0 Q2 · Q7–Q15 · Q28,Tim)· 确认队列
// ════════════════════════════════════════════════════════════════════════════
// 【这一页是什么】秤送来的读数先是一张【草稿】,工位上的人确认之后才是正式记录(规格 §6.3)。
//   · 等确认的草稿,按年龄排(永不过期,MES-0 Q13):读数、仪器、工位、读数时刻、等了几天;确认(改了读数要写理由,原值留着)
//     或驳回(理由必填,终局)。确认时选这一磅挂在哪:单独一次净重 / 开一张地磅单 / 完成一张开着的单。
//   · 手工录入一次称重:同一支转换器,一步确认;仪器可选 —— 不选,这一次标 "instrument not recorded"(Q14)。
//   · 最近确认的称重:改过的值(原值与理由)、更正(新的一行指回原行)、读数那一刻仪器在不在校准期内(Q28:只标,
//     开关开着时才拒定价与证书)。
// 【"Process received"】收件箱里刚收下的行在这里也能一键交给分派器(MES-1 Q11 说"确认队列打开时会调它")——
//   【不】在打开页面时自动调:一次 GET 不该写库;按钮就在页头,数字是这一刻收下了多少。
// 【门】requireFunction(FN.capture) = module.processing.view;确认、驳回、录入、更正要 action.confirm_capture(看得见、按不动)。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustCount, mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { ListPage } from '@/app/components/ui/list-page'
import { formatAuditStamp } from '@/lib/dates'
import CellsTable, { type CellRow } from '@/app/operation/equipment/CellsTable'
import { ProcessReceivedButton } from './inbox/InboxControls'
import { DraftActions, ManualWeighingForm, CorrectWeighing } from './CaptureControls'
import { INSTRUMENT_KINDS, type OpenTicket, type Option } from './captureFields'

type Draft = {
    id: string; inbox_id: number; device_id: string | null; station: string | null; proposed: { weight_kg?: number }
    source: string; created_at: string
}
type Weighing = {
    weighing_id: string; ticket_id: string | null; role: string; weight_kg: number; source: string; device_code: string | null
    captured_at: string; is_current: boolean; status: string
}
type Device = { id: string; code: string; name: string; kind: string; retired_at: string | null }

// 一张草稿等了几整天(永不过期,MES-0 Q13)。放在组件外:渲染里直接读时钟是 react-hooks/purity 拦的那一类。
function ageInDays(createdAt: string): number {
    return Math.max(0, Math.floor((Date.now() - new Date(createdAt).getTime()) / 86_400_000))
}

export default async function CapturePage() {
    const denied = await requireFunction(FN.capture)
    if (denied) return denied

    const t = await getTranslations()
    const supabase = await createClient()
    const canConfirm = await can('action.confirm_capture')

    const [draftRes, devRes, openRes, wRes, receivedRes] = await Promise.all([
        supabase.from('capture_drafts').select('id, inbox_id, device_id, station, proposed, source, created_at')
            .eq('status', 'pending').order('created_at').limit(200),
        supabase.from('devices').select('id, code, name, kind, retired_at').order('code'),
        supabase.from('weighbridge_ticket_weights').select('ticket_id, code, direction, vehicle_reg, status').eq('status', 'open').order('code'),
        supabase.from('weighing_calibration').select('weighing_id, ticket_id, role, weight_kg, source, device_code, captured_at, is_current, status')
            .order('captured_at', { ascending: false }).limit(50),
        supabase.from('ingest_inbox').select('id', { count: 'exact', head: true }).eq('status', 'received'),
    ])
    const drafts = mustRows(draftRes, 'capture_drafts') as Draft[]
    const devices = mustRows(devRes, 'devices') as Device[]
    const openTickets: OpenTicket[] = (mustRows(openRes, 'weighbridge_ticket_weights') as { ticket_id: string; code: string; direction: string; vehicle_reg: string }[])
        .map((o) => ({ id: o.ticket_id, code: o.code, direction: o.direction, vehicle_reg: o.vehicle_reg }))
    const weighings = mustRows(wRes, 'weighing_calibration') as Weighing[]
    const received = mustCount(receivedRes, 'ingest_inbox received')

    // 改过的值:最近这几次称重的草稿上有没有 capture_draft_changes
    const wIds = weighings.map((w) => w.weighing_id)
    const changesByWeighing = new Map<string, { original_value: unknown; confirmed_value: unknown; reason: string }>()
    const correctionReason = new Map<string, string>()
    if (wIds.length > 0) {
        const wr = mustRows(await supabase.from('weighings').select('id, draft_id, correction_reason, corrects_id').in('id', wIds), 'weighings') as
            { id: string; draft_id: string; correction_reason: string | null; corrects_id: string | null }[]
        const draftOf = new Map(wr.map((w) => [w.draft_id, w.id]))
        wr.forEach((w) => { if (w.correction_reason) correctionReason.set(w.id, w.correction_reason) })
        const ch = mustRows(await supabase.from('capture_draft_changes').select('draft_id, original_value, confirmed_value, reason')
            .in('draft_id', [...draftOf.keys()]), 'capture_draft_changes') as { draft_id: string; original_value: unknown; confirmed_value: unknown; reason: string }[]
        ch.forEach((c) => { const w = draftOf.get(c.draft_id); if (w) changesByWeighing.set(w, c) })
    }
    const tickets = new Map<string, string>()
    const tIds = [...new Set(weighings.map((w) => w.ticket_id).filter((x): x is string => !!x))]
    if (tIds.length > 0) {
        const tr = mustRows(await supabase.from('weighbridge_tickets').select('id, code').in('id', tIds), 'weighbridge_tickets') as { id: string; code: string }[]
        tr.forEach((x) => tickets.set(x.id, x.code))
    }

    const byId = new Map(devices.map((d) => [d.id, d]))
    const instruments: Option[] = devices
        .filter((d) => !d.retired_at && (INSTRUMENT_KINDS as readonly string[]).includes(d.kind))
        .map((d) => ({ id: d.id, label: `${d.code} — ${d.name}` }))

    const draftRows: CellRow[] = drafts.map((d) => {
        const dev = d.device_id ? byId.get(d.device_id) : null
        const kg = Number(d.proposed?.weight_kg ?? 0)
        const age = ageInDays(d.created_at)
        return {
            id: d.id,
            cells: {
                weight: <span className="font-medium" data-draft-weight={kg}>{t('capture.kg', { n: String(kg) })}</span>,
                device: dev ? <Link href={`/operation/devices/${dev.id}`} className="app-link hover:underline">{dev.code}</Link> : '—',
                station: d.station ?? '—',
                received: formatAuditStamp(d.created_at),
                age: t('capture.days', { n: String(age) }),
                actions: <DraftActions draftId={d.id} label={`${dev?.code ?? '#' + d.inbox_id} · ${kg} kg`} proposedKg={kg}
                                       openTickets={openTickets} canConfirm={canConfirm} />,
            },
        }
    })

    const weighingRows: CellRow[] = weighings.map((w) => {
        const change = changesByWeighing.get(w.weighing_id)
        return {
            id: w.weighing_id,
            cells: {
                at: formatAuditStamp(w.captured_at),
                weight: (
                    <span className={w.is_current ? 'font-medium' : 'line-through'}>
                        {t('capture.kg', { n: String(w.weight_kg) })}
                        {change && <span className="block text-xs text-[color:var(--brand-muted-text)]">
                            {t('capture.changedFrom', { kg: String(change.original_value), reason: change.reason })}</span>}
                        {correctionReason.get(w.weighing_id) && <span className="block text-xs text-[color:var(--brand-muted-text)]">
                            {t('capture.correctionOf', { reason: correctionReason.get(w.weighing_id)! })}</span>}
                    </span>
                ),
                role: w.ticket_id
                    ? <>{t('weighing.role.' + w.role)} · <Link href={`/operation/weighbridge/${w.ticket_id}`} className="app-link hover:underline">{tickets.get(w.ticket_id) ?? '—'}</Link></>
                    : t('weighing.role.' + w.role),
                instrument: (
                    <span data-calibration-status={w.status}>
                        {w.device_code ?? '—'}
                        <span className={`block text-xs ${w.status === 'in_calibration' ? 'text-[color:var(--brand-muted-text)]' : 'text-amber-700'}`}>
                            {t('calibration.status.' + w.status)}
                        </span>
                    </span>
                ),
                source: t('capture.source.' + w.source),
                actions: w.is_current ? <CorrectWeighing weighingId={w.weighing_id} currentKg={Number(w.weight_kg)} canConfirm={canConfirm} /> : null,
            },
        }
    })

    return (
        <ListPage
            title={t('capture.title')}
            intro={t('capture.intro')}
            maxWidth="max-w-6xl"
            actions={<ProcessReceivedButton received={received} />}
            state={{ kind: 'ok' }}
        >
            <section className="mb-8">
                <h2 className="mb-2">{t('capture.pendingTitle')}</h2>
                <CellsTable
                    columns={[
                        { key: 'weight', header: t('capture.colReading'), priority: true },
                        { key: 'device', header: t('capture.colInstrument') },
                        { key: 'station', header: t('capture.colStation') },
                        { key: 'received', header: t('capture.colReceived') },
                        { key: 'age', header: t('capture.colAge'), priority: true },
                        { key: 'actions', header: '', priority: true },
                    ]}
                    rows={draftRows}
                    empty={t('capture.noPending')}
                />
            </section>

            <section className="mb-8">
                <h2 className="mb-2">{t('capture.manualTitle')}</h2>
                <p className="mb-2 text-xs text-[color:var(--brand-muted-text)]">{t('capture.manualHint')}</p>
                <ManualWeighingForm instruments={instruments} openTickets={openTickets} canConfirm={canConfirm} />
            </section>

            <section className="mb-8">
                <h2 className="mb-2">{t('capture.recentTitle')}</h2>
                <CellsTable
                    columns={[
                        { key: 'at', header: t('capture.colWeighedAt') },
                        { key: 'weight', header: t('capture.colWeight'), priority: true },
                        { key: 'role', header: t('capture.colSubject'), priority: true },
                        { key: 'instrument', header: t('capture.colInstrument') },
                        { key: 'source', header: t('capture.colSource') },
                        { key: 'actions', header: '', priority: true },
                    ]}
                    rows={weighingRows}
                    empty={t('capture.noWeighings')}
                />
                <p className="mt-2 text-sm">
                    <Link href="/operation/calibration" className="app-link hover:underline">{t('calibration.title')}</Link>
                    {' · '}<Link href="/operation/capture/inbox" className="app-link hover:underline">{t('inbox.title')}</Link>
                </p>
            </section>
        </ListPage>
    )
}
