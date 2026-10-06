// app/operation/devices/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// MES-1(2026-10-06,MES-0 §3 · MES-1 Step 0 Q1 · Q16 · Q17 · Q26,Tim)· 设备与网关登记
// ════════════════════════════════════════════════════════════════════════════
// 【这一页是什么】车间每一个数据源(秤、地磅、放电柜、控制器、电表……)与把它们的数据带进来的网关。
//   网关的状态是【读的时候算】的(gateway_health —— 没有调度器):从没听到过 · 心跳间隔没给("Not yet set") ·
//   在沉默 · 正常。收件箱的三个数是这一刻的数,点进去是收件箱。
// 【门】requireFunction(FN.devices) = module.processing.view。登记、发 / 撤钥匙、改上限要 action.manage_devices —
//   控件看得见、按不动、说出缺哪个码(DBLOCK-1)。
// 【免费档那一行】(Q26,Tim)库还在 Supabase 免费档(闲置会暂停、没有按时间点恢复);一台真设备接上之前要换付费档(Q16)。
//   这一页读不到档位 —— 那一行是一句注明日期的陈述,Tim 说可以去掉之前一直在。
// 【机器】设备挂的资产卡经 equipment_usage 读标签(加工的人读不到 fixed_assets,Q29)。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustCount, mustOne, mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { ListPage } from '@/app/components/ui/list-page'
import { formatAuditStamp } from '@/lib/dates'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import CellsTable, { type CellRow } from '@/app/operation/equipment/CellsTable'
import DeviceForm from './DeviceForm'
import { EMPTY_DEVICE, type Option } from './deviceFields'
import IngestSettingsPanel, { type SettingValues } from './IngestSettingsPanel'

type Device = {
    id: string; code: string; name: string; kind: string; gateway_id: string | null; data_class: string | null
    station: string | null; interface_status: string; retired_at: string | null
}
type Health = {
    gateway_id: string; status: string; last_heard_at: string | null; heartbeat_interval_s: number | null; active_keys: number
}
type DataClass = { code: string; name_en: string; name_zh: string; transform_function: string | null; is_active: boolean }

export default async function DevicesPage({ searchParams }: { searchParams: Promise<{ trail?: string | string[] }> }) {
    const denied = await requireFunction(FN.devices)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const canManage = await can('action.manage_devices')

    const [devRes, healthRes, classRes, eqRes, setRes, receivedRes, failedRes, awaitingRes] = await Promise.all([
        supabase.from('devices').select('id, code, name, kind, gateway_id, data_class, station, interface_status, retired_at')
            .order('code'),
        supabase.from('gateway_health').select('gateway_id, status, last_heard_at, heartbeat_interval_s, active_keys'),
        supabase.from('ingest_data_classes').select('code, name_en, name_zh, transform_function, is_active').order('sort_order'),
        supabase.from('equipment_usage').select('equipment_id, equipment_code, equipment_description')
            .neq('equipment_status', 'disposed').order('equipment_code'),
        supabase.from('ingest_settings').select('fail_budget, fail_window_s, global_reject_budget, max_payload_bytes, max_messages, clock_ahead_s')
            .maybeSingle(),
        supabase.from('ingest_inbox').select('id', { count: 'exact', head: true }).eq('status', 'received'),
        supabase.from('ingest_inbox').select('id', { count: 'exact', head: true }).eq('status', 'failed'),
        supabase.from('ingest_inbox').select('id', { count: 'exact', head: true }).eq('status', 'awaiting_transform'),
    ])
    const devices = mustRows(devRes, 'devices') as Device[]
    const health = new Map((mustRows(healthRes, 'gateway_health') as Health[]).map((h) => [h.gateway_id, h]))
    const classes = mustRows(classRes, 'ingest_data_classes') as DataClass[]
    const equipment = mustRows(eqRes, 'equipment_usage') as { equipment_id: string; equipment_code: string; equipment_description: string | null }[]
    const settings = mustOne(setRes, 'ingest_settings') as SettingValues | null
    if (!settings) throw new Error('ingest_settings has no row — the ingestion limits cannot be shown')
    const counts = {
        received: mustCount(receivedRes, 'ingest_inbox received'),
        failed: mustCount(failedRes, 'ingest_inbox failed'),
        awaiting: mustCount(awaitingRes, 'ingest_inbox awaiting'),
    }

    const byId = new Map(devices.map((d) => [d.id, d]))
    const className = (c: DataClass) => (locale === 'zh' ? c.name_zh : c.name_en)
    const classLabel = new Map(classes.map((c) => [c.code, className(c)]))
    const gateways = devices.filter((d) => d.kind === 'gateway')
    const others = devices.filter((d) => d.kind !== 'gateway')
    const gatewayOptions: Option[] = gateways.filter((g) => !g.retired_at).map((g) => ({ id: g.id, label: `${g.code} — ${g.name}` }))
    const classOptions: Option[] = classes.filter((c) => c.is_active).map((c) => ({ id: c.code, label: className(c) }))
    const equipmentOptions: Option[] = equipment.map((m) => ({
        id: m.equipment_id, label: m.equipment_description ? `${m.equipment_code} — ${m.equipment_description}` : m.equipment_code,
    }))

    const link = (d: Device) => <Link href={`/operation/devices/${d.id}`} className="app-link hover:underline">{d.code}</Link>
    const gatewayRows: CellRow[] = gateways.map((g) => {
        const h = health.get(g.id)
        return {
            id: g.id,
            cells: {
                code: link(g),
                name: g.name,
                status: <span data-gateway-status={h?.status ?? ''}>{h ? t('devices.status.' + h.status) : '—'}</span>,
                heard: h?.last_heard_at ? formatAuditStamp(h.last_heard_at) : t('devices.neverHeard'),
                interval: h?.heartbeat_interval_s != null ? t('devices.seconds', { n: String(h.heartbeat_interval_s) }) : t('devices.notYetSet'),
                keys: String(h?.active_keys ?? 0),
            },
        }
    })
    const deviceRows: CellRow[] = others.map((d) => ({
        id: d.id,
        cells: {
            code: link(d),
            name: d.retired_at ? <span className="line-through">{d.name}</span> : d.name,
            kind: t('devices.kind.' + d.kind),
            gateway: d.gateway_id && byId.get(d.gateway_id) ? link(byId.get(d.gateway_id)!) : t('devices.noGateway'),
            dataClass: d.data_class ? classLabel.get(d.data_class) ?? d.data_class : '—',
            station: d.station ?? '—',
            interface: d.retired_at ? t('devices.retired') : t('devices.interface.' + d.interface_status),
        },
    }))

    return (
        <ListPage
            title={t('devices.title')}
            intro={t('devices.intro')}
            maxWidth="max-w-6xl"
            notices={<p className="mb-4 rounded border border-amber-300 bg-amber-50 p-3 text-sm" data-free-plan-notice="1">{t('devices.freePlan')}</p>}
            state={{ kind: 'ok' }}
        >
            <section className="mb-8">
                <h2 className="mb-2">{t('devices.inboxTitle')}</h2>
                <p className="text-sm">
                    {t('devices.inboxCounts', { received: String(counts.received), failed: String(counts.failed), awaiting: String(counts.awaiting) })}
                    {' '}<Link href="/operation/capture/inbox" className="app-link hover:underline">{t('devices.openInbox')}</Link>
                </p>
            </section>

            <section className="mb-8">
                <h2 className="mb-2">{t('devices.gatewaysTitle')}</h2>
                <CellsTable
                    columns={[
                        { key: 'code', header: t('devices.colCode'), priority: true },
                        { key: 'name', header: t('devices.colName'), priority: true },
                        { key: 'status', header: t('devices.colStatus'), priority: true },
                        { key: 'heard', header: t('devices.colLastHeard') },
                        { key: 'interval', header: t('devices.colInterval') },
                        { key: 'keys', header: t('devices.colActiveKeys'), align: 'right' },
                    ]}
                    rows={gatewayRows}
                    empty={t('devices.noGateways')}
                />
            </section>

            <section className="mb-8">
                <h2 className="mb-2">{t('devices.devicesTitle')}</h2>
                <CellsTable
                    columns={[
                        { key: 'code', header: t('devices.colCode'), priority: true },
                        { key: 'name', header: t('devices.colName'), priority: true },
                        { key: 'kind', header: t('devices.colKind') },
                        { key: 'gateway', header: t('devices.colGateway') },
                        { key: 'dataClass', header: t('devices.colDataClass') },
                        { key: 'station', header: t('devices.colStation') },
                        { key: 'interface', header: t('devices.colInterface') },
                    ]}
                    rows={deviceRows}
                    empty={t('devices.noDevices')}
                />
            </section>

            <section className="mb-8">
                <h2 className="mb-2">{t('devices.registerTitle')}</h2>
                <PermissionGate code="action.manage_devices" allowed={canManage}>
                    <DeviceForm deviceId={null} initial={EMPTY_DEVICE} gateways={gatewayOptions} classes={classOptions} equipment={equipmentOptions} />
                </PermissionGate>
            </section>

            <section className="mb-8">
                <h2 className="mb-2">{t('devices.settings.title')}</h2>
                <IngestSettingsPanel values={settings} canManage={canManage} />
            </section>

            {/* MES-1(Q22):传输上限的修改史 —— 主语 ingest_settings(单行设置作根,M5) */}
            <AuditTrail subject="ingest_settings" id="true" show={trailCount((await searchParams).trail)} />
        </ListPage>
    )
}
