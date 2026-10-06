// app/operation/devices/[id]/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// MES-1(2026-10-06,MES-0 §3 · §5.2;MES-1 Step 0 Q5 · Q16–Q21 · Q26 · Q29,Tim)· 一台设备
// ════════════════════════════════════════════════════════════════════════════
// 【网关】状态(读的时候算)· 钥匙(前缀、发、撤 —— 哈希哪里都不显示,Q20)· 它带着的设备 · 最近的调用(调用方地址标
//   "reported address (not verified)",Q18)· 按流缺的序号 · 中断(自己一块 —— 中断不进变更记录,所以不在审计记录里,Q21)·
//   传输上的异常(Q19)。
// 【别的设备】带它的网关 · 数据类 · 最近收下的消息。
// 【每一台】采购合同里的六条数据接口条款(规格 §8.1,"Not yet confirmed" 是默认)· 机器(经 equipment_usage,Q29)· 审计记录。
// 【门】requireFunction(FN.devices);修改、停用、发 / 撤钥匙要 action.manage_devices。
// ════════════════════════════════════════════════════════════════════════════
import type { ReactNode } from 'react'
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import CellsTable, { type CellRow } from '@/app/operation/equipment/CellsTable'
import DeviceControls from '../DeviceControls'
import KeysPanel, { type KeyRow } from '../KeysPanel'
import { TERM_KEYS, type DeviceValues, type Option } from '../deviceFields'
import { INSTRUMENT_KINDS } from '@/app/operation/capture/captureFields'
import { RecordCalibrationForm, VoidCalibration } from '@/app/operation/calibration/CalibrationControls'

type Device = {
    id: string; code: string; name: string; kind: string; gateway_id: string | null; data_class: string | null
    equipment_id: string | null; station: string | null; capacity: number | null; resolution: number | null; unit: string | null
    protection_rating: string | null; interface_status: string; heartbeat_interval_s: number | null; notes: string | null
    retired_at: string | null; retire_reason: string | null
} & Record<(typeof TERM_KEYS)[number], string>

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export default async function DevicePage({ params, searchParams }: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ trail?: string | string[] }>
}) {
    const denied = await requireFunction(FN.devices)
    if (denied) return denied
    const { id } = await params
    if (!UUID.test(id)) notFound()

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const canManage = await can('action.manage_devices')

    const d = mustOne(await supabase.from('devices')
        .select('id, code, name, kind, gateway_id, data_class, equipment_id, station, capacity, resolution, unit, protection_rating, interface_status, heartbeat_interval_s, notes, retired_at, retire_reason, term_protocol, term_point_list, term_timestamp_precision, term_no_charge, term_retention_export, term_documentation')
        .eq('id', id).maybeSingle(), 'device') as Device | null
    if (!d) notFound()
    const isGateway = d.kind === 'gateway'

    const [allRes, classRes, eqRes] = await Promise.all([
        supabase.from('devices').select('id, code, name, kind, gateway_id, retired_at').order('code'),
        supabase.from('ingest_data_classes').select('code, name_en, name_zh, is_active').order('sort_order'),
        supabase.from('equipment_usage').select('equipment_id, equipment_code, equipment_description, equipment_status').order('equipment_code'),
    ])
    const all = mustRows(allRes, 'devices') as { id: string; code: string; name: string; kind: string; gateway_id: string | null; retired_at: string | null }[]
    const classes = mustRows(classRes, 'ingest_data_classes') as { code: string; name_en: string; name_zh: string; is_active: boolean }[]
    const equipment = mustRows(eqRes, 'equipment_usage') as { equipment_id: string; equipment_code: string; equipment_description: string | null; equipment_status: string }[]
    const className = (c: { name_en: string; name_zh: string }) => (locale === 'zh' ? c.name_zh : c.name_en)
    const byId = new Map(all.map((x) => [x.id, x]))
    const machine = d.equipment_id ? equipment.find((m) => m.equipment_id === d.equipment_id) ?? null : null
    const link = (x: { id: string; code: string }) => <Link href={`/operation/devices/${x.id}`} className="app-link hover:underline">{x.code}</Link>

    const gatewayOptions: Option[] = all.filter((g) => g.kind === 'gateway' && !g.retired_at).map((g) => ({ id: g.id, label: `${g.code} — ${g.name}` }))
    const classOptions: Option[] = classes.filter((c) => c.is_active).map((c) => ({ id: c.code, label: className(c) }))
    const equipmentOptions: Option[] = equipment.filter((m) => m.equipment_status !== 'disposed').map((m) => ({
        id: m.equipment_id, label: m.equipment_description ? `${m.equipment_code} — ${m.equipment_description}` : m.equipment_code,
    }))
    const initial: DeviceValues = {
        name: d.name, kind: d.kind, gateway_id: d.gateway_id ?? '', data_class: d.data_class ?? '', equipment_id: d.equipment_id ?? '',
        station: d.station ?? '', capacity: d.capacity != null ? String(d.capacity) : '', resolution: d.resolution != null ? String(d.resolution) : '',
        unit: d.unit ?? '', protection_rating: d.protection_rating ?? '', interface_status: d.interface_status,
        heartbeat_interval_s: d.heartbeat_interval_s != null ? String(d.heartbeat_interval_s) : '', notes: d.notes ?? '',
        term_protocol: d.term_protocol, term_point_list: d.term_point_list, term_timestamp_precision: d.term_timestamp_precision,
        term_no_charge: d.term_no_charge, term_retention_export: d.term_retention_export, term_documentation: d.term_documentation,
    }

    const termRows: CellRow[] = TERM_KEYS.map((k) => ({
        id: k, cells: { term: t('devices.terms.' + k), state: t('devices.termState.' + d[k]) },
    }))

    // ── 网关那几块 ──────────────────────────────────────────────────────────
    let gatewayBlocks: ReactNode = null
    if (isGateway) {
        const [hRes, kRes, tRes, oRes, gRes, aRes] = await Promise.all([
            supabase.from('gateway_health').select('status, last_heard_at, last_call_at, last_heartbeat_at, active_keys').eq('gateway_id', id).maybeSingle(),
            supabase.from('gateway_keys_masked').select('id, key_prefix, issued_at, revoked_at, revoke_reason').eq('gateway_id', id).order('issued_at'),
            supabase.from('ingest_transmissions')
                .select('id, received_at, result, message_count, accepted_count, duplicate_count, rejected_count, stream, first_seq, last_seq, client_address, bytes')
                .eq('gateway_id', id).eq('kind', 'call').order('id', { ascending: false }).limit(50),
            supabase.from('gateway_outages').select('id, silent_from, silent_to, interval_s').eq('gateway_id', id).order('silent_from', { ascending: false }),
            supabase.from('ingest_sequence_gaps').select('stream, missing_from, missing_to, missing_count').eq('gateway_id', id),
            supabase.from('ingest_transmission_anomalies').select('occurred_at, anomaly, seq, occurrences, client_address, transmission_id, inbox_id')
                .eq('gateway_id', id).order('occurred_at', { ascending: false }).limit(50),
        ])
        const h = mustOne(hRes, 'gateway_health') as { status: string; last_heard_at: string | null; last_call_at: string | null; last_heartbeat_at: string | null; active_keys: number } | null
        const keys = mustRows(kRes, 'gateway_keys_masked') as { id: string; key_prefix: string; issued_at: string; revoked_at: string | null; revoke_reason: string | null }[]
        const calls = mustRows(tRes, 'ingest_transmissions') as {
            id: number; received_at: string; result: string; message_count: number | null; accepted_count: number | null
            duplicate_count: number | null; rejected_count: number | null; stream: string | null; first_seq: number | null
            last_seq: number | null; client_address: string; bytes: number }[]
        const outages = mustRows(oRes, 'gateway_outages') as { id: number; silent_from: string; silent_to: string; interval_s: number }[]
        const gaps = mustRows(gRes, 'ingest_sequence_gaps') as { stream: string; missing_from: number; missing_to: number; missing_count: number }[]
        const anomalies = mustRows(aRes, 'ingest_transmission_anomalies') as {
            occurred_at: string; anomaly: string; seq: number | null; occurrences: number; client_address: string | null
            transmission_id: number | null; inbox_id: number | null }[]
        const carried = all.filter((x) => x.gateway_id === id)
        const keyRows: KeyRow[] = keys.map((k) => ({
            id: k.id, prefix: k.key_prefix, issued_at: formatAuditStamp(k.issued_at),
            revoked_at: k.revoked_at ? formatAuditStamp(k.revoked_at) : null, revoked_by: null, revoke_reason: k.revoke_reason,
        }))
        gatewayBlocks = (
            <>
                <section className="mt-8">
                    <h2 className="mb-2">{t('devices.statusTitle')}</h2>
                    <p className="text-sm" data-gateway-status={h?.status ?? ''}>
                        <strong>{h ? t('devices.status.' + h.status) : '—'}</strong>
                        {h?.status === 'interval_not_set' && <> · {t('devices.statusIntervalNotSet')}</>}
                        {h?.status === 'not_yet_heard' && <> · {t('devices.statusNotYetHeard')}</>}
                    </p>
                    <p className="mt-1 text-sm">
                        {t('devices.lastHeard')}: {h?.last_heard_at ? formatAuditStamp(h.last_heard_at) : t('devices.neverHeard')} ·{' '}
                        {t('devices.lastCall')}: {h?.last_call_at ? formatAuditStamp(h.last_call_at) : '—'} ·{' '}
                        {t('devices.lastHeartbeat')}: {h?.last_heartbeat_at ? formatAuditStamp(h.last_heartbeat_at) : '—'}
                    </p>
                    <p className="mt-2 rounded border border-amber-300 bg-amber-50 p-3 text-sm" data-free-plan-notice="1">{t('devices.freePlan')}</p>
                </section>

                <section className="mt-8">
                    <h2 className="mb-2">{t('devices.keys.title')}</h2>
                    <KeysPanel gatewayId={id} gatewayCode={d.code} rows={keyRows} canManage={canManage} retired={!!d.retired_at} />
                </section>

                <section className="mt-8">
                    <h2 className="mb-2">{t('devices.carriedTitle')}</h2>
                    <CellsTable
                        columns={[{ key: 'code', header: t('devices.colCode'), priority: true }, { key: 'name', header: t('devices.colName'), priority: true },
                                  { key: 'kind', header: t('devices.colKind') }]}
                        rows={carried.map((x) => ({ id: x.id, cells: { code: link(x), name: x.name, kind: t('devices.kind.' + x.kind) } }))}
                        empty={t('devices.carriedNone')}
                    />
                </section>

                <section className="mt-8">
                    <h2 className="mb-2">{t('devices.callsTitle')}</h2>
                    <p className="mb-2 text-xs text-[color:var(--brand-muted-text)]">{t('devices.addressHint')}</p>
                    <CellsTable
                        columns={[
                            { key: 'at', header: t('devices.colAt'), priority: true },
                            { key: 'result', header: t('devices.colResult'), priority: true },
                            { key: 'messages', header: t('devices.colMessages') },
                            { key: 'seq', header: t('devices.colStreamSeq') },
                            { key: 'address', header: t('devices.colAddress') },
                        ]}
                        rows={calls.map((c) => ({
                            id: String(c.id),
                            cells: {
                                at: formatAuditStamp(c.received_at),
                                result: t('devices.result.' + c.result),
                                messages: c.message_count != null
                                    ? t('devices.messagesCounts', { n: String(c.message_count), a: String(c.accepted_count ?? 0),
                                                                    d: String(c.duplicate_count ?? 0), r: String(c.rejected_count ?? 0) })
                                    : '—',
                                seq: c.stream ? `${c.stream} · ${c.first_seq ?? '—'}–${c.last_seq ?? '—'}` : '—',
                                address: c.client_address,
                            },
                        }))}
                        empty={t('devices.callsNone')}
                    />
                </section>

                <section className="mt-8">
                    <h2 className="mb-2">{t('devices.gapsTitle')}</h2>
                    <CellsTable
                        columns={[{ key: 'stream', header: t('devices.colStream'), priority: true },
                                  { key: 'range', header: t('devices.colMissing'), priority: true }, { key: 'n', header: t('devices.colCount'), align: 'right' }]}
                        rows={gaps.map((g, i) => ({ id: `${g.stream}-${i}`, cells: { stream: g.stream, range: `${g.missing_from}–${g.missing_to}`, n: String(g.missing_count) } }))}
                        empty={t('devices.gapsNone')}
                    />
                </section>

                {/* Q21:中断不进变更记录(MES-0 Q14),所以它不在下面那一块审计记录里 —— 在这里自己一块。 */}
                <section className="mt-8">
                    <h2 className="mb-2">{t('devices.outagesTitle')}</h2>
                    <CellsTable
                        columns={[{ key: 'from', header: t('devices.colSilentFrom'), priority: true }, { key: 'to', header: t('devices.colSilentTo'), priority: true },
                                  { key: 'interval', header: t('devices.colInterval') }]}
                        rows={outages.map((o) => ({ id: String(o.id), cells: {
                            from: formatAuditStamp(o.silent_from), to: formatAuditStamp(o.silent_to),
                            interval: t('devices.seconds', { n: String(o.interval_s) }) } }))}
                        empty={t('devices.outagesNone')}
                    />
                </section>

                <section className="mt-8">
                    <h2 className="mb-2">{t('devices.anomaliesTitle')}</h2>
                    <p className="mb-2 text-xs text-[color:var(--brand-muted-text)]">{t('devices.anomaliesHint')}</p>
                    <CellsTable
                        columns={[{ key: 'at', header: t('devices.colAt'), priority: true }, { key: 'what', header: t('devices.colAnomaly'), priority: true },
                                  { key: 'seq', header: t('devices.colSeq') }, { key: 'n', header: t('devices.colCount'), align: 'right' },
                                  { key: 'address', header: t('devices.colAddress') }]}
                        rows={anomalies.map((a, i) => ({ id: `${a.transmission_id ?? ''}-${a.inbox_id ?? ''}-${i}`, cells: {
                            at: formatAuditStamp(a.occurred_at), what: t('devices.anomaly.' + a.anomaly), seq: a.seq != null ? String(a.seq) : '—',
                            n: String(a.occurrences), address: a.client_address ?? '—' } }))}
                        empty={t('devices.anomaliesNone')}
                    />
                </section>
            </>
        )
    }

    // ── 别的设备:最近收下的消息 ──────────────────────────────────────────────
    let messagesBlock: ReactNode = null
    if (!isGateway) {
        const rows = mustRows(await supabase.from('ingest_inbox')
            .select('id, received_at, stream, seq, status, data_class').eq('device_id', id).order('id', { ascending: false }).limit(20),
            'ingest_inbox') as { id: number; received_at: string; stream: string | null; seq: number | null; status: string; data_class: string }[]
        messagesBlock = (
            <section className="mt-8">
                <h2 className="mb-2">{t('devices.messagesTitle')}</h2>
                <CellsTable
                    columns={[{ key: 'at', header: t('devices.colAt'), priority: true }, { key: 'status', header: t('devices.colStatus'), priority: true },
                              { key: 'seq', header: t('devices.colStreamSeq') }]}
                    rows={rows.map((r) => ({ id: String(r.id), cells: {
                        at: formatAuditStamp(r.received_at), status: t('inbox.status.' + r.status),
                        seq: r.stream ? `${r.stream} · ${r.seq}` : '—' } }))}
                    empty={t('devices.messagesNone')}
                />
                <p className="mt-2 text-sm"><Link href="/operation/capture/inbox" className="app-link hover:underline">{t('devices.openInbox')}</Link></p>
            </section>
        )
    }

    // MES-2(Q23 · Q24 · Q25):秤 / 地磅 / 电表 / 在线仪表 —— 今天在不在校准期内,与它的每一条校准记录(只追加;记错的作废)
    let calibrationBlock: ReactNode = null
    if ((INSTRUMENT_KINDS as readonly string[]).includes(d.kind)) {
        const [recRes, nowRes] = await Promise.all([
            supabase.from('instrument_calibrations')
                .select('id, calibrated_on, valid_until, result, certificate_no, calibrating_body, notes, recorded_at, voided_at, void_reason')
                .eq('device_id', id).order('calibrated_on', { ascending: false }).order('id', { ascending: false }),
            supabase.from('instrument_calibration_now').select('status, approaching').eq('device_id', id).maybeSingle(),
        ])
        const records = mustRows(recRes, 'instrument_calibrations') as {
            id: number; calibrated_on: string; valid_until: string; result: string; certificate_no: string | null
            calibrating_body: string | null; notes: string | null; recorded_at: string; voided_at: string | null; void_reason: string | null
        }[]
        const now = mustOne(nowRes, 'instrument_calibration_now') as { status: string; approaching: boolean } | null
        const recRows: CellRow[] = records.map((r) => ({
            id: String(r.id),
            cells: {
                calibrated: <span className={r.voided_at ? 'line-through' : ''}>{formatDate(r.calibrated_on, locale)}</span>,
                validUntil: formatDate(r.valid_until, locale),
                result: t('calibration.result.' + r.result),
                certificate: [r.certificate_no, r.calibrating_body].filter(Boolean).join(' · ') || '—',
                recorded: (
                    <span>{formatAuditStamp(r.recorded_at)}
                        {r.voided_at && <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('calibration.voidedNote', { reason: r.void_reason ?? '' })}</span>}
                    </span>
                ),
                actions: r.voided_at || d.retired_at ? null
                    : <VoidCalibration id={r.id} deviceId={id} label={`${d.code} · ${r.calibrated_on}`} canManage={canManage} />,
            },
        }))
        calibrationBlock = (
            <section className="mt-8">
                <h2 className="mb-2">{t('calibration.deviceTitle')}</h2>
                <p className="mb-2 text-sm" data-calibration-status={now?.status ?? ''}>
                    {now ? t('calibration.status.' + now.status) : '—'}
                    {now?.approaching && <span className="ml-2 text-amber-700">{t('calibration.approaching')}</span>}
                </p>
                <CellsTable
                    columns={[
                        { key: 'calibrated', header: t('calibration.colCalibratedOn'), priority: true },
                        { key: 'validUntil', header: t('calibration.colValidUntil'), priority: true },
                        { key: 'result', header: t('calibration.colResult') },
                        { key: 'certificate', header: t('calibration.colCertificate') },
                        { key: 'recorded', header: t('calibration.colRecorded') },
                        { key: 'actions', header: '', priority: true },
                    ]}
                    rows={recRows}
                    empty={t('calibration.noRecords')}
                />
                {!d.retired_at && (
                    <div className="mt-3">
                        <RecordCalibrationForm instruments={[]} canManage={canManage} presetDeviceId={id} />
                    </div>
                )}
                <p className="mt-2 text-sm"><Link href="/operation/calibration" className="app-link hover:underline">{t('calibration.title')}</Link></p>
            </section>
        )
    }

    const gw = d.gateway_id ? byId.get(d.gateway_id) ?? null : null
    const dataClass = d.data_class ? classes.find((c) => c.code === d.data_class) ?? null : null

    return (
        <ListPage
            breadcrumb={<Link href="/operation/devices" className="app-link hover:underline text-sm">← {t('devices.title')}</Link>}
            title={`${d.code} · ${d.name}`}
            maxWidth="max-w-6xl"
            state={{ kind: 'ok' }}
        >
            <RecordHeader
                fields={[
                    { label: t('devices.colCode'), value: d.code, mono: true },
                    { label: t('devices.colKind'), value: t('devices.kind.' + d.kind) },
                    { label: t('devices.colInterface'), value: d.retired_at ? t('devices.retired') : t('devices.interface.' + d.interface_status) },
                    ...(isGateway
                        ? [{ label: t('devices.colInterval'), value: d.heartbeat_interval_s != null ? t('devices.seconds', { n: String(d.heartbeat_interval_s) }) : t('devices.notYetSet') }]
                        : [{ label: t('devices.colGateway'), value: gw ? link(gw) : t('devices.noGateway') },
                           { label: t('devices.colDataClass'), value: dataClass ? className(dataClass) : '—' }]),
                    { label: t('devices.colStation'), value: d.station ?? '—' },
                    { label: t('devices.form.machine'), value: machine ? `${machine.equipment_code}${machine.equipment_description ? ` — ${machine.equipment_description}` : ''}` : '—' },
                    ...(!isGateway ? [
                        { label: t('devices.form.capacity'), value: d.capacity != null ? `${d.capacity}${d.unit ? ` ${d.unit}` : ''}` : t('devices.notYetSet') },
                        { label: t('devices.form.resolution'), value: d.resolution != null ? `${d.resolution}${d.unit ? ` ${d.unit}` : ''}` : t('devices.notYetSet') },
                    ] : []),
                    { label: t('devices.form.protection'), value: d.protection_rating ?? '—' },
                    ...(d.retired_at ? [{ label: t('devices.retired'), value: `${formatAuditStamp(d.retired_at)} · ${d.retire_reason ?? ''}` }] : []),
                ]}
            />
            {d.notes && <p className="mb-4 text-sm">{d.notes}</p>}

            <DeviceControls deviceId={id} code={d.code} initial={initial} gateways={gatewayOptions} classes={classOptions}
                            equipment={equipmentOptions} canManage={canManage} retired={!!d.retired_at} />

            {gatewayBlocks}
            {messagesBlock}
            {calibrationBlock}

            <section className="mt-8">
                <h2 className="mb-2">{t('devices.terms.title')}</h2>
                <p className="mb-2 text-xs text-[color:var(--brand-muted-text)]">{t('devices.terms.hint')}</p>
                <CellsTable columns={[{ key: 'term', header: t('devices.terms.colTerm'), priority: true }, { key: 'state', header: t('devices.terms.colState'), priority: true }]}
                            rows={termRows} empty="—" />
            </section>

            <AuditTrail subject="device" id={id} show={trailCount((await searchParams).trail)} />
        </ListPage>
    )
}
