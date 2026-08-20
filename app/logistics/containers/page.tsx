// app/logistics/containers/page.tsx
// LOG-2b:集装箱名单。读的是 container_overview(属主权限视图,门写在视图体里)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import LogisticsSubnav from '../Subnav'
import NewContainerForm from './NewContainerForm'

export default async function ContainersPage() {
    const denied = await requireModule(MOD.logistics)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const rows = mustRows(
        await supabase.from('container_overview').select('*').order('departure_date', { ascending: false }),
        'container_overview'
    )
    const ports = mustRows(
        await supabase.from('ports').select('id, code, name').is('deleted_at', null),
        'ports'
    )
    const lanes = mustRows(
        await supabase.from('lanes').select('id, origin_port_id, destination_port_id').is('deleted_at', null),
        'lanes'
    )
    const forwarders = mustRows(
        await supabase.from('suppliers').select('id, legal_name')
            .eq('counterparty_type', 'forwarder').is('deleted_at', null).order('legal_name'),
        'forwarders'
    )
    const portName = new Map(ports.map((p) => [p.id as string, `${p.code} ${p.name}`]))
    const laneLabel = (id: string | null) => {
        const l = lanes.find((x) => x.id === id)
        return l ? `${portName.get(l.origin_port_id as string) ?? '?'} → ${portName.get(l.destination_port_id as string) ?? '?'}` : '—'
    }

    // 【单据那一栏:三种状态三句话,不折叠成一个数字】
    const docCell = (r: Record<string, unknown>) => {
        const st = r.lane_checklist_state as string
        if (st === 'not_defined') return <span className="text-amber-900">{t('logistics.checklistNotDefined')}</span>
        if (st === 'defined_empty') return <span className="text-gray-600">{t('logistics.checklistDefinedEmpty')}</span>
        if (st === 'no_lane') return <span className="text-gray-500">—</span>
        const n = Number(r.documents_pending ?? 0)
        return n > 0 ? t('logistics.docsPending', { 0: String(n) }) : t('logistics.docsAllIn')
    }

    return (
        <div className="p-8">
            <h1 className="text-2xl font-bold mb-4">{t('logistics.containersTitle')}</h1>
            <LogisticsSubnav />

            <NewContainerForm
                lanes={lanes.map((l) => ({ id: l.id as string, label: laneLabel(l.id as string) }))}
                forwarders={forwarders.map((f) => ({ id: f.id as string, label: f.legal_name as string }))}
                labels={{
                    heading: t('logistics.newContainer'),
                    lane: t('logistics.colLane'),
                    departure: t('logistics.colDeparture'),
                    departureHint: t('logistics.departureHint'),
                    containerNumber: t('logistics.colContainerNumber'),
                    vessel: t('logistics.colVessel'),
                    voyage: t('logistics.colVoyage'),
                    forwarder: t('logistics.colName'),
                    bl: t('logistics.blNumber'),
                    blHint: t('logistics.blHint'),
                    submit: t('logistics.newContainer'),
                    noLanes: t('logistics.noLanes'),
                }}
            />

            {rows.length === 0 ? (
                <p className="mt-6 max-w-2xl rounded border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-900">
                    {t('logistics.emptyContainers')}
                </p>
            ) : (
                <div className="mt-6 overflow-x-auto">
                    <table className="w-full border-collapse border border-gray-300 text-sm">
                        <thead className="bg-gray-100">
                            <tr>
                                {[t('logistics.colContainerCode'), t('logistics.colContainerNumber'),
                                  t('logistics.colLane'), t('logistics.colVessel'), t('logistics.colDeparture'),
                                  t('logistics.colLatestMilestone'), t('logistics.colShipments'),
                                  t('logistics.colDocuments')].map((h) => (
                                    <th key={h} className="border border-gray-300 px-3 py-2 text-left">{h}</th>
                                ))}
                            </tr>
                        </thead>
                        <tbody>
                            {rows.map((r) => (
                                <tr key={r.id as string}>
                                    <td className="border border-gray-300 px-3 py-1">
                                        <Link href={`/logistics/containers/${r.id}`} className="text-blue-700 hover:underline font-mono text-xs">
                                            {r.code as string}
                                        </Link>
                                    </td>
                                    <td className="border border-gray-300 px-3 py-1 font-mono text-xs">{(r.container_number as string) ?? '—'}</td>
                                    <td className="border border-gray-300 px-3 py-1">{laneLabel(r.lane_id as string | null)}</td>
                                    <td className="border border-gray-300 px-3 py-1">{(r.vessel as string) ?? '—'}</td>
                                    <td className="border border-gray-300 px-3 py-1">{r.departure_date as string}</td>
                                    <td className="border border-gray-300 px-3 py-1">
                                        {r.latest_milestone
                                            ? `${t('logistics.milestoneLabel.' + (r.latest_milestone as string))} · ${r.latest_milestone_date as string}`
                                            : <span className="text-gray-500">—</span>}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-1 text-right">{String(r.shipment_count ?? 0)}</td>
                                    <td className="border border-gray-300 px-3 py-1">{docCell(r as Record<string, unknown>)}</td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </div>
            )}
        </div>
    )
}
