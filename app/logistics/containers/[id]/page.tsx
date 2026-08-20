// app/logistics/containers/[id]/page.tsx
// LOG-2b:集装箱详情 —— 头、装着的发货单、里程碑、单据清单。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import LogisticsSubnav from '../../Subnav'
import ContainerPanels from './ContainerPanels'
import ContainerFreightPanel from './ContainerFreightPanel'

export default async function ContainerDetailPage({ params }: { params: Promise<{ id: string }> }) {
    const denied = await requireModule(MOD.logistics)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const head = await supabase
        .from('containers')
        .select('id, code, container_number, vessel, voyage, bl_number, notes, departure_date, lane_id, forwarder_id, expected_arrival_date')
        .eq('id', id).is('deleted_at', null).maybeSingle()
    if (head.error) throw new Error(head.error.message)
    if (!head.data) notFound()

    // CTN-FWD:承运方候选与当前那一家的名字。【只列货代】—— 与运费录入页
    // 那一处同向(.eq),与其余十一处 .neq 相反,所以它单独写在这里。
    const forwarders = mustRows(
        await supabase.from('suppliers').select('id, legal_name')
            .is('deleted_at', null).eq('counterparty_type', 'forwarder').order('legal_name'),
        'forwarders'
    ) as unknown as { id: string; legal_name: string }[]
    // 【先把它取到一个局部里】—— notFound() 的收窄跨不过回调,
    // 在 .find() 里再读 head.data 会被 TS 判成可能为 null。
    const fwdId = head.data.forwarder_id as string | null
    const forwarderName = fwdId
        ? (forwarders.find((f) => f.id === fwdId)?.legal_name ?? null)
        : null

    const ov = await supabase.from('container_overview').select('lane_checklist_state').eq('id', id).maybeSingle()
    if (ov.error) throw new Error(ov.error.message)

    const attached = mustRows(
        await supabase.from('shipments')
            .select('id, code, ship_date, sales_orders ( code, customers ( legal_name ) )')
            .eq('container_id', id).order('ship_date'),
        'attached shipments'
    )
    const attachable = mustRows(
        await supabase.from('shipments')
            .select('id, code, ship_date, sales_orders ( code, customers ( legal_name ) )')
            .is('container_id', null).order('ship_date'),
        'attachable shipments'
    )
    const milestones = mustRows(
        await supabase.from('container_milestones')
            .select('id, milestone, event_date, note, recorded_at')
            .eq('container_id', id).order('event_date', { ascending: false }).order('recorded_at', { ascending: false }),
        'milestones'
    )
    const documents = mustRows(
        await supabase.from('container_documents')
            .select('id, document_type, regime, status, na_reason, from_lane')
            .eq('container_id', id).order('from_lane', { ascending: false }).order('document_type'),
        'documents'
    )

    const shape = (r: Record<string, unknown>) => {
        const so = r.sales_orders as { code: string; customers: { legal_name: string } | null } | null
        return {
            id: r.id as string, code: r.code as string, ship_date: r.ship_date as string,
            order_code: so?.code ?? '—', customer: so?.customers?.legal_name ?? '—',
        }
    }

    return (
        <div className="p-8">
            <div className="mb-4">
                <Link href="/logistics/containers" className="text-blue-600 hover:underline text-sm">{t('common.back')}</Link>
            </div>
            <h1 className="text-2xl font-bold mb-1 font-mono">{head.data.code}</h1>
            <p className="mb-4 text-sm text-gray-500">
                {t('logistics.colDeparture')}: {head.data.departure_date}
            </p>
            <LogisticsSubnav />

            <ContainerPanels
                containerId={id}
                head={{
                    container_number: head.data.container_number,
                    vessel: head.data.vessel,
                    voyage: head.data.voyage,
                    bl_number: head.data.bl_number,
                    notes: head.data.notes,
                    expected_arrival_date: head.data.expected_arrival_date as string | null,
                    forwarder_id: fwdId,
                    forwarder_name: forwarderName,
                }}
                forwarders={forwarders.map((f) => ({ id: f.id, name: f.legal_name }))}
                hasLane={head.data.lane_id !== null}
                laneChecklistState={(ov.data?.lane_checklist_state as string) ?? 'no_lane'}
                attached={attached.map((r) => shape(r as Record<string, unknown>))}
                attachable={attachable.map((r) => shape(r as Record<string, unknown>))}
                milestones={milestones.map((m) => ({
                    id: m.id as string, milestone: m.milestone as string,
                    event_date: m.event_date as string, note: (m.note as string | null) ?? null,
                    label: t('logistics.milestoneLabel.' + (m.milestone as string)),
                }))}
                documents={documents.map((d) => ({
                    id: d.id as string, document_type: d.document_type as string,
                    regime: (d.regime as string | null) ?? null, status: d.status as string,
                    na_reason: (d.na_reason as string | null) ?? null, from_lane: d.from_lane as boolean,
                }))}
                // 【真源是库里那条 CHECK】(db/tables/container_milestones.sql)。
                // 这里只决定【下拉的顺序】;往库里加一个里程碑时,check-i18n 会立刻
                // 要求两个语言补标签(manifest 接的就是那条 CHECK),于是这一行不会被悄悄落下。
                milestoneTypes={['booked','gated_in','loaded','departed','arrived','customs_cleared','delivered','other']
                    .map((m) => ({ value: m, label: t('logistics.milestoneLabel.' + m) }))}
                labels={{
                    headHeading: t('logistics.headHeading'),
                    containerNumber: t('logistics.colContainerNumber'), vessel: t('logistics.colVessel'),
                    voyage: t('logistics.colVoyage'), bl: t('logistics.blNumber'), blHint: t('logistics.blHint'),
                    notes: t('logistics.notes'), save: t('common.save'),
                    shipmentsHeading: t('logistics.shipmentsHeading'), shipmentsEmpty: t('logistics.shipmentsEmpty'),
                    attach: t('logistics.attach'), attachEmpty: t('logistics.attachEmpty'),
                    detach: t('logistics.detach'), detachReason: t('logistics.detachReason'),
                    milestonesHeading: t('logistics.milestonesHeading'), milestonesEmpty: t('logistics.milestonesEmpty'),
                    milestone: t('logistics.milestone'), eventDate: t('logistics.eventDate'),
                    eventDateHint: t('logistics.eventDateHint'), milestoneNote: t('logistics.milestoneNote'),
                    addMilestone: t('logistics.addMilestone'), correctionNote: t('logistics.correctionNote'),
                    documentsHeading: t('logistics.documentsHeading'), instantiate: t('logistics.instantiate'),
                    fromLane: t('logistics.fromLane'), handAdded: t('logistics.handAdded'),
                    statusPending: t('logistics.statusPending'), statusReceived: t('logistics.statusReceived'),
                    statusNa: t('logistics.statusNa'), naReason: t('logistics.naReason'),
                    addDocument: t('logistics.addDocument'), documentType: t('logistics.documentType'),
                    regime: t('logistics.regime'),
                    notDefined: t('logistics.checklistNotDefined'), definedEmpty: t('logistics.checklistDefinedEmpty'),
                    noLane: t('logistics.noLaneOnContainer'),
                    // LOG-5b
                    etaLabel: t('logistics.etaLabel'), etaHint: t('logistics.etaHint'),
                    checklistDefinedNotInstantiated: t('logistics.checklistDefinedNotInstantiated'),
                    // CTN-FWD
                    forwarderLabel: t('logistics.containerForwarder'),
                    forwarderNone: t('logistics.containerForwarderNone'),
                    forwarderHint: t('logistics.containerForwarderHint'),
                }}
            />

            {/* LOG-4b:运费面板 —— 服务端渲染,只读。它不属于 ContainerPanels
                (那是编辑态的客户端组件),所以不往那条已经很宽的 props 里再塞一层。 */}
            <ContainerFreightPanel
                containerId={id}
                laneId={head.data.lane_id as string | null}
                forwarderId={head.data.forwarder_id as string | null}
                departureDate={head.data.departure_date as string}
            />
        </div>
    )
}
