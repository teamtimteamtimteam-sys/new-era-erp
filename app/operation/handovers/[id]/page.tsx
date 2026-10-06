// app/operation/handovers/[id]/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1b-1(Tim 的 Q23)· 一次交接班 —— 交接的内容、提到的停机,底部是它的审计记录
// ════════════════════════════════════════════════════════════════════════════
// 【为什么有它】交接班原来只有一张清单,交接的内容与提到的停机哪儿都看不到;审计记录也就没有地方住。
// 【门】requireModule(MOD.processing) —— 与清单同一道门;交接班三张表的读规则也是这个码。
// 【名字走 handover_people】与清单同一个理由:employees 要人事权限,而这一页的读者是车间的人。
// 【签收】与清单同一颗按钮,同一道门(action.processing_aftercare 或 module.processing.edit;
//   库里只让被点名的接班人签得动)。未签收是一个【具名的状态】,不是一格空白。
// 【入口】清单的日期那一格链到这里;提交一张新的交接班之后直接落到这一页(Q23)。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
import { formatAuditStamp, formatDate, formatDateTime } from '@/lib/dates'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import AcknowledgeButton from '../AcknowledgeButton'
import CellsTable, { type CellRow } from '../../equipment/CellsTable'

type Handover = {
    id: string; shift_code: string; handover_date: string; outgoing_employee_id: string; incoming_employee_id: string
    notes: string | null; submitted_at: string; acknowledged_at: string | null; acknowledged_by: string | null
}

export default async function HandoverPage({ params, searchParams }: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ trail?: string | string[] }>
}) {
    const denied = await requireModule(MOD.processing)
    if (denied) return denied

    const { id } = await params
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const canEdit = (await can('action.processing_aftercare')) || (await can('module.processing.edit'))

    const h = mustOne(await supabase.from('shift_handovers')
        .select('id, shift_code, handover_date, outgoing_employee_id, incoming_employee_id, notes, submitted_at, acknowledged_at, acknowledged_by')
        .eq('id', id).maybeSingle(), 'shift_handovers') as Handover | null
    if (!h) notFound()

    const [items, refs, people, shifts, types] = await Promise.all([
        supabase.from('shift_handover_items').select('id, item_type_code, body, sort_order').eq('handover_id', id).order('sort_order'),
        supabase.from('shift_handover_equipment_refs').select('downtime_id').eq('handover_id', id),
        supabase.from('handover_people').select('id, code, preferred_name'),
        supabase.from('shifts').select('code, name_en, name_zh, starts_at, ends_at'),
        supabase.from('handover_item_types').select('code, name_en, name_zh'),
    ])
    const itemRows = mustRows(items, 'shift_handover_items') as { id: string; item_type_code: string; body: string }[]
    const refRows = mustRows(refs, 'shift_handover_equipment_refs') as { downtime_id: string }[]
    const peopleRows = mustRows(people, 'handover_people') as { id: string; code: string; preferred_name: string | null }[]
    const shiftRows = mustRows(shifts, 'shifts') as { code: string; name_en: string; name_zh: string; starts_at: string | null; ends_at: string | null }[]
    const typeRows = mustRows(types, 'handover_item_types') as { code: string; name_en: string; name_zh: string }[]

    // 提到的停机:停机那一行 + 哪一台机器(equipment_usage,加工的人读得到)
    const downIds = refRows.map((r) => r.downtime_id)
    // U1-B(Q15):一段停机可以在交接【之后】被作废。交接单不动(那是交接时说过的话),
    //   但读它的人要知道那一段后来被收回了 —— 所以 voided_at / void_reason 一起读,画一个标记。
    const downRows = downIds.length === 0 ? [] : mustRows(await supabase.from('equipment_downtime')
        .select('id, equipment_id, started_at, ended_at, reason, voided_at, void_reason').in('id', downIds), 'equipment_downtime') as
        { id: string; equipment_id: string; started_at: string; ended_at: string | null; reason: string
          voided_at: string | null; void_reason: string | null }[]
    const eqIds = [...new Set(downRows.map((d) => d.equipment_id))]
    const machines = eqIds.length === 0 ? [] : mustRows(await supabase.from('equipment_usage')
        .select('equipment_id, equipment_code').in('equipment_id', eqIds), 'equipment_usage') as { equipment_id: string; equipment_code: string }[]

    const nameOf = (pid: string | null) => {
        if (!pid) return '—'
        const p = peopleRows.find((x) => x.id === pid)
        return p ? (p.preferred_name ?? p.code) : '—'
    }
    const sft = shiftRows.find((x) => x.code === h.shift_code)
    const shiftLabel = !sft ? h.shift_code
        : sft.starts_at && sft.ends_at
            ? `${locale === 'zh' ? sft.name_zh : sft.name_en} ${sft.starts_at.slice(0, 5)}–${sft.ends_at.slice(0, 5)}`
            : `${locale === 'zh' ? sft.name_zh : sft.name_en}(${t('processing.handover.hoursUnstated')})`
    const typeName = (code: string) => {
        const ty = typeRows.find((x) => x.code === code)
        return ty ? (locale === 'zh' ? ty.name_zh : ty.name_en) : code
    }

    const itemTable: CellRow[] = itemRows.map((r) => ({
        id: r.id,
        cells: { type: typeName(r.item_type_code), body: <span className="whitespace-pre-wrap break-words">{r.body}</span> },
    }))
    const downTable: CellRow[] = downRows.map((d) => {
        const m = machines.find((x) => x.equipment_id === d.equipment_id)
        return {
            id: d.id,
            cells: {
                machine: m ? <Link href={`/operation/equipment/${d.equipment_id}`} className="app-link hover:underline">{m.equipment_code}</Link> : '—',
                from: formatDateTime(d.started_at, locale),
                // U1-B:后来作废了的一段 —— 不再说"还没结束",说"后来作废了"。原因照交接时那样留着(不划掉:
                //   交接单记的是那时说过的话),下面一行是作废的理由。
                to: d.voided_at ? (
                    <span className="inline-flex flex-wrap items-center gap-1.5">
                        {d.ended_at && <span className="line-through text-gray-400">{formatDateTime(d.ended_at, locale)}</span>}
                        <span className="rounded bg-gray-100 px-2 py-0.5 text-xs text-gray-600" data-downtime-voided="1">{t('processing.handover.downtimeVoidedLater')}</span>
                    </span>
                ) : d.ended_at ? formatDateTime(d.ended_at, locale)
                    : <span className="rounded bg-amber-100 px-2 py-0.5 text-xs text-amber-900">{t('processing.handover.downtimeOngoing')}</span>,
                reason: d.voided_at ? (
                    <span className="break-words">
                        {d.reason}
                        <span className="block text-xs text-[color:var(--brand-muted-text)]">
                            {t('equipment.down.voidedBecause', { reason: d.void_reason ?? '—', when: formatDateTime(d.voided_at, locale) })}
                        </span>
                    </span>
                ) : <span className="break-words">{d.reason}</span>,
            },
        }
    })

    return (
        <ListPage
            maxWidth="max-w-3xl"
            breadcrumb={<Link href="/operation/handovers" className="hover:underline text-sm app-link">{t('common.back')}</Link>}
            title={t('processing.handover.title')}
            state={{ kind: 'ok' }}
        >
            <RecordHeader
                fields={[
                    { label: t('processing.handover.colDate'), value: formatDate(h.handover_date, locale) },
                    { label: t('processing.handover.colShift'), value: shiftLabel },
                    { label: t('processing.handover.colFrom'), value: nameOf(h.outgoing_employee_id) },
                    { label: t('processing.handover.colTo'), value: nameOf(h.incoming_employee_id) },
                    {
                        label: t('processing.handover.colAck'),
                        value: h.acknowledged_at ? (
                            <span className="inline-block px-2 py-0.5 rounded bg-green-100 text-green-800 text-xs">
                                {t('processing.handover.acknowledgedBy', { who: nameOf(h.acknowledged_by), when: formatAuditStamp(h.acknowledged_at) })}
                            </span>
                        ) : (
                            <span className="flex flex-wrap items-center gap-2">
                                <span className="inline-block px-2 py-0.5 rounded bg-amber-200 text-amber-900 text-xs font-medium">
                                    {t('processing.handover.pending')}
                                </span>
                                <PermissionGate code="action.processing_aftercare" allowed={canEdit}>
                                    <AcknowledgeButton handoverId={h.id} />
                                </PermissionGate>
                            </span>
                        ),
                    },
                ]}
            />
            <p className="text-xs text-[color:var(--brand-muted-text)] mt-4">{t('processing.handover.cannotAnswerYet')}</p>

            {h.notes && (
                <section className="mt-6">
                    <h2 className="mb-2">{t('processing.handover.notes')}</h2>
                    <p className="text-sm whitespace-pre-wrap break-words">{h.notes}</p>
                </section>
            )}

            <section className="mt-6">
                <h2 className="mb-2">{t('processing.handover.itemsTitle')}</h2>
                <CellsTable
                    columns={[
                        { key: 'type', header: t('processing.handover.colType'), priority: true },
                        { key: 'body', header: t('processing.handover.notes'), priority: true },
                    ]}
                    rows={itemTable}
                    empty={t('processing.handover.noItems')}
                />
            </section>

            <section className="mt-6">
                <h2 className="mb-2">{t('processing.handover.equipmentTitle')}</h2>
                <CellsTable
                    columns={[
                        { key: 'machine', header: t('processing.handover.colMachine'), priority: true },
                        { key: 'from', header: t('equipment.down.colFrom'), priority: true },
                        { key: 'to', header: t('equipment.down.colTo') },
                        { key: 'reason', header: t('equipment.down.colReason') },
                    ]}
                    rows={downTable}
                    empty={t('processing.handover.noEquipment')}
                />
            </section>

            {/* AUDIT-TRAIL-1b-1(Q23):提交 · 交接内容 · 提到的停机 · 签收 */}
            <AuditTrail subject="shift_handover" id={id} show={trailCount((await searchParams).trail)} />
        </ListPage>
    )
}
