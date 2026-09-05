// app/logistics/containers/page.tsx
// LOG-2b:集装箱名单。读的是 container_overview(属主权限视图,门写在视图体里)。
//
// CONV-5:套 CONV-1 的两文件模板。
// ★ state 恒为 'ok' —— NewContainerForm 是这一页【开一只新箱】的唯一出口,
//   而它今天就画在行数判断之外。走 empty 分支会把它藏起来。见 §⑩-3。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import NewContainerForm from './NewContainerForm'
import { ListPage } from '@/app/components/ui/list-page'
import ContainersTable, { type ContainerRow } from './ContainersTable'

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
        await supabase.from('supplier_lookup').select('id, legal_name')
            .eq('counterparty_type', 'forwarder').is('deleted_at', null).order('legal_name'),
        'forwarders'
    )
    const portName = new Map(ports.map((p) => [p.id as string, `${p.code} ${p.name}`]))
    const laneLabel = (id: string | null) => {
        const l = lanes.find((x) => x.id === id)
        return l ? `${portName.get(l.origin_port_id as string) ?? '?'} → ${portName.get(l.destination_port_id as string) ?? '?'}` : '—'
    }

    // 【单据那一栏:三种状态三句话,不折叠成一个数字】
    // 判据留在服务端,列描述符只画算好的那句话 + 它该用的色调。
    const docCell = (r: Record<string, unknown>): { label: string; tone: ContainerRow['docsTone'] } => {
        const st = r.lane_checklist_state as string
        if (st === 'not_defined') return { label: t('logistics.checklistNotDefined'), tone: 'warn' }
        if (st === 'defined_empty') return { label: t('logistics.checklistDefinedEmpty'), tone: 'muted' }
        if (st === 'no_lane') return { label: '—', tone: 'none' }
        const n = Number(r.documents_pending ?? 0)
        return {
            label: n > 0 ? t('logistics.docsPending', { 0: String(n) }) : t('logistics.docsAllIn'),
            tone: 'plain',
        }
    }

    const tableRows: ContainerRow[] = rows.map((r) => {
        const doc = docCell(r as Record<string, unknown>)
        return {
            id: r.id as string,
            code: r.code as string,
            containerNumber: (r.container_number as string) ?? '—',
            laneLabel: laneLabel(r.lane_id as string | null),
            vessel: (r.vessel as string) ?? '—',
            departureDate: r.departure_date as string,
            milestoneLabel: r.latest_milestone
                ? `${t('logistics.milestoneLabel.' + (r.latest_milestone as string))} · ${r.latest_milestone_date as string}`
                : null,
            shipmentCount: String(r.shipment_count ?? 0),
            docsLabel: doc.label,
            docsTone: doc.tone,
        }
    })

    return (
        <ListPage title={t('logistics.containersTitle')} state={{ kind: 'ok' }}>
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

            <div className="mt-6">
                <ContainersTable rows={tableRows} empty={t('logistics.emptyContainers')} />
            </div>
        </ListPage>
    )
}
