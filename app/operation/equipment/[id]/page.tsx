// app/operation/equipment/[id]/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1b-1(Tim 的 Q22 · Q14)· 一台机器 —— 加工的人读得到的那一份,只读,底部是它的审计记录
// ════════════════════════════════════════════════════════════════════════════
// 【门】requireModule(MOD.processing)。审计记录的主语 equipment 的根表是 fixed_assets(只给财务读),所以它用
//   M3:页面的码就是门,资产卡自己的那几次改动对不持财务权限的读者是 Restricted(Q4);保养、停机、保养周期、
//   交接班里提到的停机照常说。
// 【读什么,不读什么】
//   读:equipment_usage(编号、说明、状态、日期、加工量)· equipment_service_status(保养周期与到期状态)·
//       equipment_maintenance / equipment_downtime(这两张表给加工与财务读)· processing_runs_masked(最近的加工单)·
//       handover_people(做保养的员工 —— employees 要人事权限)· supplier_lookup(做保养的供应商)。
//   ★ 不读 equipment_maintenance_advice(Q14):它把资产成本与维修花费给了持加工权限的人 ——
//     已登记在 docs/known-issues.md(AT1B-EQUIPMENT-ADVICE-SHOWS-COSTS)。也不读 fixed_assets / 费用 / 折旧。
// 【财务的人】多一个链接去资产卡(/finance/assets/[id]);记保养、记停机、改周期仍在那一页上。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
import { Refusal } from '@/app/components/ui/refusal'
import { formatDate, formatDateTime } from '@/lib/dates'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import CellsTable, { type CellRow } from '../CellsTable'

const KG = new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 })

type Usage = {
    equipment_id: string; equipment_code: string; equipment_description: string | null; equipment_status: string
    acquisition_date: string | null; in_service_date: string | null; run_count: number
    input_kg: number; output_kg: number; loss_kg: number; first_run_date: string | null; last_run_date: string | null
}
type Service = {
    interval_id: string | null; monitored: boolean; service_kind: string | null; disposition: string | null
    kg_since: number | null; days_since: number | null; is_due: boolean | null; due_reason: string | null
    is_approaching: boolean | null; approaching_reason: string | null
}
type Work = {
    id: string; performed_on: string; kind: string; description: string; performed_by_name: string | null
    performed_by_employee_id: string | null; performed_by_supplier_id: string | null; capitalised: boolean
}
// U1-B(Q15):voided_at / void_reason —— 作废的那一段照旧列出、标着「已作废」与理由,而【不】画成"还在停"。
type Down = {
    id: string; started_at: string; ended_at: string | null; reason: string; notes: string | null
    voided_at: string | null; void_reason: string | null
}
type Run = { id: string; code: string; process_date: string | null; total_input: number | null; total_output: number | null }

export default async function EquipmentPage({ params, searchParams }: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ trail?: string | string[] }>
}) {
    const denied = await requireModule(MOD.processing)
    if (denied) return denied

    const { id } = await params
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const usage = mustOne(await supabase.from('equipment_usage').select('*').eq('equipment_id', id).maybeSingle(), 'equipment_usage') as Usage | null
    if (!usage) notFound()

    const [service, work, down, runs, people, suppliers] = await Promise.all([
        supabase.from('equipment_service_status')
            .select('interval_id, monitored, service_kind, disposition, kg_since, days_since, is_due, due_reason, is_approaching, approaching_reason')
            .eq('equipment_id', id),
        supabase.from('equipment_maintenance')
            .select('id, performed_on, kind, description, performed_by_name, performed_by_employee_id, performed_by_supplier_id, capitalised')
            .eq('equipment_id', id).order('performed_on', { ascending: false }),
        supabase.from('equipment_downtime')
            .select('id, started_at, ended_at, reason, notes, voided_at, void_reason').eq('equipment_id', id).order('started_at', { ascending: false }),
        supabase.from('processing_runs_masked')
            .select('id, code, process_date, total_input, total_output')
            .eq('equipment_id', id).is('deleted_at', null).order('process_date', { ascending: false }).limit(10),
        supabase.from('handover_people').select('id, code, preferred_name'),
        supabase.from('supplier_lookup').select('id, legal_name'),
    ])
    const serviceRows = mustRows(service, 'equipment_service_status') as Service[]
    const workRows = mustRows(work, 'equipment_maintenance') as Work[]
    const downRows = mustRows(down, 'equipment_downtime') as Down[]
    const runRows = mustRows(runs, 'processing_runs_masked') as Run[]
    const peopleRows = mustRows(people, 'handover_people') as { id: string; code: string; preferred_name: string | null }[]
    const supplierRows = mustRows(suppliers, 'supplier_lookup') as { id: string; legal_name: string }[]
    const canFinance = await can('module.finance.view')
    const restricted = <Refusal>{t('common.restricted')}</Refusal>

    // 做这件事的人:员工 → handover_people(不要人事权限);供应商 → supplier_lookup;都没有 → 手打的名字。
    // 挂着一个 id 却查不到名字 = 一个权限答复,画成"受限",不画成空白。
    const performer = (w: Work) => {
        if (w.performed_by_employee_id) {
            const p = peopleRows.find((x) => x.id === w.performed_by_employee_id)
            return p ? (p.preferred_name ?? p.code) : restricted
        }
        if (w.performed_by_supplier_id) {
            return supplierRows.find((x) => x.id === w.performed_by_supplier_id)?.legal_name ?? restricted
        }
        return w.performed_by_name ?? '—'
    }
    const reasonWord = (r: string | null) =>
        r === 'kg+days' ? t('equipment.intervals.reasonBoth') : r === 'kg' ? t('equipment.intervals.reasonKg') : r === 'days' ? t('equipment.intervals.reasonDays') : ''
    const serviceState = (s: Service) => {
        if (!s.monitored) return <span className="text-[color:var(--brand-muted-text)]">{t('equipment.intervals.notMonitored')}</span>
        if (s.is_due) return <span className="rounded bg-red-100 px-2 py-0.5 text-xs text-red-800">{t('equipment.intervals.stateDue')} {reasonWord(s.due_reason)}</span>
        if (s.is_approaching) return <span className="rounded bg-amber-100 px-2 py-0.5 text-xs text-amber-900">{t('equipment.intervals.stateApproaching')} {reasonWord(s.approaching_reason)}</span>
        return <span className="rounded bg-green-100 px-2 py-0.5 text-xs text-green-800">{t('equipment.intervals.stateOk')}</span>
    }
    // 动态前缀 equipment.kind.,后缀集合接 equipment_maintenance / equipment_service_intervals 的 CHECK(service · repair)
    const kindLabel = (k: string | null) => (k === 'repair' ? t('equipment.kind.repair') : k === 'service' ? t('equipment.kind.service') : '—')

    const serviceTable: CellRow[] = serviceRows.map((s, i) => ({
        id: s.interval_id ?? `none-${i}`,
        cells: {
            kind: kindLabel(s.service_kind),
            state: serviceState(s),
            kg: s.kg_since === null ? '—' : `${KG.format(Number(s.kg_since))} kg`,
            days: s.days_since === null ? '—' : String(s.days_since),
        },
    }))
    const workTable: CellRow[] = workRows.map((w) => ({
        id: w.id,
        cells: {
            date: formatDate(w.performed_on, locale),
            kind: kindLabel(w.kind),
            what: <span className="break-words">{w.description}</span>,
            who: performer(w),
            cap: w.capitalised ? t('equipment.maint.capitalised') : '—',
        },
    }))
    // U1-B:作废的一段没有发生过 —— 起止划掉、「已作废」一枚(在"回来"那一格,它在手机上留着),
    //   原因划掉、下面一行是作废的理由。开着却作废了的一段【不】说"还在停"。
    const downTable: CellRow[] = downRows.map((d) => ({
        id: d.id,
        cells: d.voided_at ? {
            from: <span className="line-through text-gray-400">{formatDateTime(d.started_at, locale)}</span>,
            to: (
                <span className="inline-flex flex-wrap items-center gap-1.5">
                    {d.ended_at && <span className="line-through text-gray-400">{formatDateTime(d.ended_at, locale)}</span>}
                    <span className="rounded bg-gray-100 px-2 py-0.5 text-xs text-gray-600" data-downtime-voided="1">{t('equipment.down.voidedBadge')}</span>
                </span>
            ),
            reason: (
                <span className="break-words">
                    <span className="line-through text-gray-400">{d.reason}</span>
                    <span className="block text-xs text-[color:var(--brand-muted-text)]">
                        {t('equipment.down.voidedBecause', { reason: d.void_reason ?? '—', when: formatDateTime(d.voided_at, locale) })}
                    </span>
                </span>
            ),
        } : {
            from: formatDateTime(d.started_at, locale),
            to: d.ended_at ? formatDateTime(d.ended_at, locale)
                : <span className="rounded bg-amber-100 px-2 py-0.5 text-xs text-amber-900">{t('equipment.down.stillDown')}</span>,
            reason: <span className="break-words">{d.reason}</span>,
        },
    }))
    const runTable: CellRow[] = runRows.map((r) => ({
        id: r.id,
        cells: {
            code: <Link href={`/operation/processing/${r.id}`} className="app-link hover:underline">{r.code}</Link>,
            date: r.process_date ? formatDate(r.process_date, locale) : '—',
            input: r.total_input === null ? '—' : `${KG.format(Number(r.total_input))} kg`,
            output: r.total_output === null ? '—' : `${KG.format(Number(r.total_output))} kg`,
        },
    }))

    return (
        <ListPage
            maxWidth="max-w-3xl"
            breadcrumb={<Link href="/operation/equipment" className="hover:underline text-sm app-link">{t('common.back')}</Link>}
            title={t('equipment.page.detailTitle')}
            intro={t('equipment.page.readOnly')}
            actions={canFinance ? (
                <Link href={`/finance/assets/${id}`} className="app-link hover:underline text-sm">{t('equipment.page.financeCard')}</Link>
            ) : undefined}
            state={{ kind: 'ok' }}
        >
            <RecordHeader
                fields={[
                    { label: t('equipment.page.colCode'), value: usage.equipment_code, mono: true },
                    { label: t('equipment.page.colDescription'), value: usage.equipment_description ?? '—' },
                    { label: t('equipment.page.colStatus'), value: t('assets.status.' + usage.equipment_status) },
                    { label: t('equipment.page.acquired'), value: usage.acquisition_date ? formatDate(usage.acquisition_date, locale) : '—' },
                    { label: t('equipment.page.inService'), value: usage.in_service_date ? formatDate(usage.in_service_date, locale) : '—' },
                    { label: t('equipment.page.colRuns'), value: String(usage.run_count) },
                    { label: t('equipment.page.colProcessed'), value: `${KG.format(Number(usage.input_kg))} kg` },
                    { label: t('equipment.page.output'), value: `${KG.format(Number(usage.output_kg))} kg` },
                    { label: t('equipment.page.loss'), value: `${KG.format(Number(usage.loss_kg))} kg` },
                    { label: t('equipment.page.firstRun'), value: usage.first_run_date ? formatDate(usage.first_run_date, locale) : '—' },
                    { label: t('equipment.page.colLastRun'), value: usage.last_run_date ? formatDate(usage.last_run_date, locale) : '—' },
                ]}
            />

            <section className="mt-8">
                <h2 className="mb-2">{t('equipment.page.serviceTitle')}</h2>
                <CellsTable
                    columns={[
                        { key: 'kind', header: t('equipment.intervals.kind'), priority: true },
                        { key: 'state', header: t('equipment.page.colStatus'), priority: true },
                        { key: 'kg', header: t('equipment.page.kgSince'), align: 'right' },
                        { key: 'days', header: t('equipment.page.daysSince'), align: 'right' },
                    ]}
                    rows={serviceTable}
                    empty={t('equipment.intervals.notMonitoredWhy')}
                />
            </section>

            <section className="mt-8">
                <h2 className="mb-2">{t('equipment.maint.title')}</h2>
                <CellsTable
                    columns={[
                        { key: 'date', header: t('equipment.maint.colDate'), priority: true },
                        { key: 'kind', header: t('equipment.maint.colKind') },
                        { key: 'what', header: t('equipment.maint.colWhat'), priority: true },
                        { key: 'who', header: t('equipment.maint.colWho') },
                        { key: 'cap', header: t('equipment.maint.colCapital') },
                    ]}
                    rows={workTable}
                    empty={t('equipment.maint.none')}
                />
            </section>

            <section className="mt-8">
                <h2 className="mb-2">{t('equipment.down.title')}</h2>
                <CellsTable
                    columns={[
                        { key: 'from', header: t('equipment.down.colFrom'), priority: true },
                        { key: 'to', header: t('equipment.down.colTo'), priority: true },
                        { key: 'reason', header: t('equipment.down.colReason') },
                    ]}
                    rows={downTable}
                    empty={t('equipment.down.none')}
                />
            </section>

            <section className="mt-8">
                <h2 className="mb-2">{t('equipment.page.runsTitle')}</h2>
                <CellsTable
                    columns={[
                        { key: 'code', header: t('processing.colCode'), priority: true },
                        { key: 'date', header: t('processing.detail.processDate'), priority: true },
                        { key: 'input', header: t('processing.detail.totalInput'), align: 'right' },
                        { key: 'output', header: t('processing.detail.totalOutput'), align: 'right' },
                    ]}
                    rows={runTable}
                    empty={t('equipment.page.noRuns')}
                />
            </section>

            {/* AUDIT-TRAIL-1b-1(Q22):保养 · 停机 · 保养周期 · 交接班里提到的停机;资产卡自己的改动只给财务看(M3 · Q4) */}
            <AuditTrail subject="equipment" id={id} show={trailCount((await searchParams).trail)} />
        </ListPage>
    )
}
