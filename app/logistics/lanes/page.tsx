// app/logistics/lanes/page.tsx
// LOG-1c:航段与它们的单据清单。
//
// 【航段不是货代的属性】,所以它不在货代详情页里 —— 一条航段上可以有很多家货代报价。
// 【清单的三种状态在这里是三句不同的话】:没人定过 / 定过且确认不需要 / 定过并列了要求。
// 中间那一种是【某个人做过的一个决定】,不是"零条要求" —— 屏幕上必须说出这件事。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import LanesPanel from './LanesPanel'
import { can } from '@/lib/permissions'
import ListTrail, { type ListTrailRecord } from '@/app/components/trail/ListTrail'
import { trailCount } from '@/app/components/trail/AuditTrail'

export default async function LanesPage({ searchParams }: { searchParams: Promise<{ trail?: string }> }) {
    const denied = await requireModule(MOD.logistics)
    if (denied) return denied
    const canEditGate = await can('module.purchasing.edit')

    const supabase = await createClient()
    const t = await getTranslations()

    const ports = mustRows(
        await supabase.from('ports').select('id, code, name').is('deleted_at', null).order('code'),
        'ports'
    )
    const lanes = mustRows(
        await supabase.from('lanes').select('id, origin_port_id, destination_port_id').is('deleted_at', null),
        'lanes'
    )
    const status = mustRows(
        await supabase.from('lane_checklist_status').select('lane_id, checklist_state, requirement_count'),
        'lane_checklist_status'
    )
    const reqs = mustRows(
        await supabase.from('lane_document_requirements')
            .select('id, lane_id, document_type, regime').is('deleted_at', null),
        'lane_document_requirements'
    )

    const portLabel = new Map(ports.map((p) => [p.id as string, `${p.code} ${p.name}`]))

    // AUDIT-TRAIL-1b-2:航段与港口没有详情页 —— 页底一块合起来的审计记录,每一条航段、每一个港口各读一次。
    //   【删掉的也读】清单只列在用的,而"被删掉了"正是审计记录要说的事;所以这里单独取全部(含 deleted_at)。
    const [allPorts, allLanes] = await Promise.all([
        supabase.from('ports').select('id, code, name').order('code'),
        supabase.from('lanes').select('id, origin_port_id, destination_port_id'),
    ])
    const portsAll = mustRows(allPorts, 'ports (audit trail)')
    const allPortLabel = new Map(portsAll.map((p) => [p.id as string, `${p.code} ${p.name}`]))
    const trailRecords: ListTrailRecord[] = [
        ...mustRows(allLanes, 'lanes (audit trail)').map((l) => ({ subject: 'lane' as const, id: l.id as string,
            label: `${allPortLabel.get(l.origin_port_id as string) ?? '?'} → ${allPortLabel.get(l.destination_port_id as string) ?? '?'}` })),
        ...portsAll.map((p) => ({ subject: 'port' as const, id: p.id as string, label: `${p.code} ${p.name}` })),
    ]
    const stateOf = new Map(status.map((s) => [s.lane_id as string, s.checklist_state as string]))

    return (
        <div className="p-8">
            <h1 className="mb-4">{t('logistics.lanesTitle')}</h1>
            <LanesPanel canEdit={canEditGate}
                ports={ports.map((p) => ({ id: p.id as string, label: `${p.code} ${p.name}` }))}
                lanes={lanes.map((l) => ({
                    id: l.id as string,
                    label: `${portLabel.get(l.origin_port_id as string) ?? '?'} → ${portLabel.get(l.destination_port_id as string) ?? '?'}`,
                    state: stateOf.get(l.id as string) ?? 'not_defined',
                    requirements: reqs.filter((r) => r.lane_id === l.id).map((r) => ({
                        id: r.id as string, document_type: r.document_type as string, regime: (r.regime as string | null) ?? null,
                    })),
                }))}
                labels={{
                    addPort: t('logistics.addPort'), portCode: t('logistics.portCode'), portName: t('logistics.portName'),
                    addLane: t('logistics.addLane'), origin: t('logistics.origin'), destination: t('logistics.destination'),
                    noLanes: t('logistics.noLanes'),
                    checklistHeading: t('logistics.checklistHeading'),
                    notDefined: t('logistics.checklistNotDefined'),
                    definedEmpty: t('logistics.checklistDefinedEmpty'),
                    defined: t('logistics.checklistDefined'),
                    markReviewed: t('logistics.markReviewed'),
                    documentType: t('logistics.documentType'),
                    regime: t('logistics.regime'), regimeHint: t('logistics.regimeHint'),
                    addRequirement: t('logistics.addRequirement'),
                    removeRequirement: t('logistics.removeRequirement'),
                }}
            />
            <ListTrail records={trailRecords} intro="listTrail.intro.lanes" show={trailCount((await searchParams).trail)} />
        </div>
    )
}
