// app/operation/equipment/[id]/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1b-1(Tim 的 Q22 · Q14)· 一台机器 —— 加工的人读得到的那一份,底部是它的审计记录
// ★ MES-7a-1(2026-10-15,MES-7a Step 0 Q5 · Q6,Tim):【这一页也是记它的地方了】—— 停机、保养维修、保养间隔三组表单从财务的资产卡
//   (/finance/assets/[id])搬到这里,写只经五支函数;码不变(module.processing.edit,仓库不加)。资产卡照旧读它们、照旧资本化。
//   上面多一行可靠性(MTBF / MTTR,equipment_reliability,默认整段记录),说出分母;整张表在 /operation/equipment/reliability。
// ════════════════════════════════════════════════════════════════════════════
// 【门】requireModule(MOD.processing)。审计记录的主语 equipment 的根表是 fixed_assets(只给财务读),所以它用
//   M3:页面的码就是门,资产卡自己的那几次改动对不持财务权限的读者是 Restricted(Q4)。
// 【读什么,以及读不到的时候说什么】
//   equipment_usage(编号、说明、状态、日期、加工量)· equipment_service_status · equipment_maintenance · equipment_downtime ·
//   equipment_maintenance_advice(维修花费与机器成本只给持 module.finance.view 的人 —— 视图自己遮,U1-A)· downtime_causes ·
//   maintenance_settings · processing_runs_masked · supplier_lookup。
//   员工下拉读 employees_masked(人事的门):不持 module.hr.view 不给员工那个选项,并说出理由。
//   支出单下拉读 expenses(财务的门)、阈值提示要机器的记录成本(fixed_assets,财务的表):不持 module.finance.view 时两处各说一句,
//   不画一个空下拉、不印一个 0。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustCount, mustOne, mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
import { formatAmount } from '@/lib/format'
import { getBaseCurrency } from '@/lib/currency'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import CellsTable, { type CellRow } from '../CellsTable'
import DowntimePanel, { type DowntimeRow } from './DowntimePanel'
import MaintenancePanel from './MaintenancePanel'
import ServiceIntervalPanel, { type IntervalRow } from './ServiceIntervalPanel'
import SparePartsPanel, { type PartIssueRow, type PartStock } from './SparePartsPanel'
import LinkedIncidents from '@/app/components/safety/LinkedIncidents'
import { loadDowntimeCauses, reliabilityWords, type ReliabilityRow } from '../reliability'

const KG = new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 })

type Usage = {
    equipment_id: string; equipment_code: string; equipment_description: string | null; equipment_status: string
    acquisition_date: string | null; in_service_date: string | null; run_count: number
    input_kg: number; output_kg: number; loss_kg: number; first_run_date: string | null; last_run_date: string | null
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
    const baseCurrency = await getBaseCurrency()

    const usage = mustOne(await supabase.from('equipment_usage').select('*').eq('equipment_id', id).maybeSingle(), 'equipment_usage') as Usage | null
    if (!usage) notFound()

    const [canRecord, canFinance, canFinanceEdit, canHr, canIssueParts, canSeeStock, canSeePrices] = await Promise.all([
        can('module.processing.edit'), can('module.finance.view'), can('module.finance.edit'), can('module.hr.view'),
        // MES-7a-2:备件出库与退回的码(Q12);备件库存的读码;件的金额只给看得见价格的人
        can('module.inventory.edit'), can('module.inventory.view'), can('data.view_prices'),
    ])

    const [statusRes, maintRes, adviceRes, downRes, runsRes, supRes, settingsRes, rel] = await Promise.all([
        supabase.from('equipment_service_status')
            .select('interval_id, monitored, service_kind, disposition, interval_kg, lead_kg, interval_days, lead_days, last_service_date, never_serviced, baseline_date, kg_since, days_since, unattributed_runs_in_window, is_due, due_reason, is_approaching, approaching_reason')
            .eq('equipment_id', id),
        supabase.from('equipment_maintenance')
            .select('id, performed_on, kind, description, capitalised, capitalisation_reason, performed_by_employee_id, performed_by_supplier_id, performed_by_name, expense_id, capitalised_expense_id, downtime_id')
            .eq('equipment_id', id).order('performed_on', { ascending: false }),
        supabase.from('equipment_maintenance_advice')
            .select('maintenance_id, work_cost_base, pct_of_equipment_cost, meets_threshold').eq('equipment_id', id),
        supabase.from('equipment_downtime')
            .select('id, started_at, ended_at, reason, notes, duration, voided_at, voided_by, void_reason, cause_code')
            .eq('equipment_id', id).order('started_at', { ascending: false }),
        supabase.from('processing_runs_masked')
            .select('id, code, process_date, total_input, total_output')
            .eq('equipment_id', id).is('deleted_at', null).order('process_date', { ascending: false }).limit(10),
        supabase.from('supplier_lookup').select('id, code, legal_name').is('deleted_at', null).order('code').limit(200),
        supabase.from('maintenance_settings').select('capitalise_pct_of_cost, capitalise_floor_base').maybeSingle(),
        supabase.rpc('equipment_reliability', { p_equipment_id: id }),
    ])
    const statusRows = mustRows(statusRes, 'equipment_service_status') as unknown as IntervalRow[]
    const maintRaw = mustRows(maintRes, 'equipment_maintenance') as {
        id: string; performed_on: string; kind: string; description: string; capitalised: boolean; capitalisation_reason: string | null
        performed_by_employee_id: string | null; performed_by_supplier_id: string | null; performed_by_name: string | null
        expense_id: string | null; capitalised_expense_id: string | null; downtime_id: string | null }[]
    const downRows = mustRows(downRes, 'equipment_downtime') as unknown as DowntimeRow[]
    const runRows = mustRows(runsRes, 'processing_runs_masked') as Run[]
    const settings = mustOne(settingsRes, 'maintenance_settings') as { capitalise_pct_of_cost: number | null; capitalise_floor_base: number | null } | null
    const relRow = (mustRows(rel, 'equipment_reliability') as unknown as ReliabilityRow[])[0] ?? null
    const adviceById = new Map((mustRows(adviceRes, 'equipment_maintenance_advice') as {
        maintenance_id: string; work_cost_base: number | null; pct_of_equipment_cost: number | null; meets_threshold: boolean | null }[])
        .map((a) => [a.maintenance_id, a]))
    const causes = await loadDowntimeCauses(supabase, locale, t)

    // 员工下拉:人事的门 —— 不持 module.hr.view 不给这个选项(面板下面说一句为什么),不给一个只看得见自己的下拉
    const employees = canHr
        ? (mustRows(await supabase.from('employees_masked').select('id, code, legal_name').is('deleted_at', null).order('code').limit(200),
                    'employees_masked') as { id: string; code: string; legal_name: string }[])
            .map((e) => ({ id: e.id, label: `${e.code} · ${e.legal_name}` }))
        : []
    const suppliers = (mustRows(supRes, 'supplier_lookup') as { id: string; code: string; legal_name: string }[])
        .map((x) => ({ id: x.id, label: `${x.code} · ${x.legal_name}` }))
    // 支出单与机器的记录成本:财务的门。读不到 = null(面板说"要财务查看码"),不是一个空清单、也不是 0
    const expenses = canFinance
        ? (mustRows(await supabase.from('expenses').select('id, code, expense_date, amount_base, status')
                .eq('status', 'posted').order('expense_date', { ascending: false }).limit(100), 'expenses') as
                { id: string; code: string; expense_date: string; amount_base: number }[])
            .map((e) => ({ id: e.id, label: `${e.code} · ${e.expense_date} · ${formatAmount(Number(e.amount_base), baseCurrency)}` }))
        : null
    const costBase = canFinance
        ? Number((mustOne(await supabase.from('fixed_assets').select('cost_base').eq('id', id).maybeSingle(), 'fixed_assets') as
                  { cost_base: number } | null)?.cost_base ?? 0)
        : null

    // 取得日之前、谁都没归属的在册加工(间隔面板那句诚实话的输入,与资产卡同一个问法)
    const runsBeforeAcquisition = usage.acquisition_date
        ? mustCount(await supabase.from('processing_runs_masked').select('id', { count: 'exact', head: true })
            .is('equipment_id', null).is('deleted_at', null).eq('status', 'committed').lt('process_date', usage.acquisition_date),
            'processing_runs_masked prior runs')
        : 0

    const empName = new Map(employees.map((e) => [e.id, e.label]))
    const supName = new Map(suppliers.map((x) => [x.id, x.label]))
    const causeLabel = new Map(causes.map((c) => [c.code, c.label]))
    const downLabel = (d: DowntimeRow) =>
        `${formatAuditStamp(d.started_at)} · ${d.cause_code ? (causeLabel.get(d.cause_code) ?? d.cause_code) : t('equipment.down.notClassified')} · ${d.reason}`
    const downById = new Map(downRows.map((d) => [d.id, d]))
    const maintRows = maintRaw.map((m) => {
        const adv = adviceById.get(m.id)
        const dt = m.downtime_id ? downById.get(m.downtime_id) : undefined
        return {
            id: m.id, performed_on: formatDate(m.performed_on, locale), kind: m.kind, description: m.description,
            capitalised: m.capitalised, capitalisation_reason: m.capitalisation_reason, capitalised_expense_id: m.capitalised_expense_id,
            performer: m.performed_by_employee_id
                ? (empName.get(m.performed_by_employee_id) ?? t('common.restricted'))
                : m.performed_by_supplier_id
                ? (supName.get(m.performed_by_supplier_id) ?? t('common.restricted'))
                : (m.performed_by_name ?? '—'),
            expense_code: null,
            work_cost_base: adv?.work_cost_base ?? null,
            pct_of_equipment_cost: adv?.pct_of_equipment_cost ?? null,
            meets_threshold: adv?.meets_threshold ?? null,
            downtime_label: dt ? downLabel(dt) : null,
        }
    })
    const linkableDowntimes = downRows.filter((d) => d.voided_at === null).map((d) => ({ id: d.id, label: downLabel(d) }))

    // ── MES-7a-2:这台机器的保养记录上出过的备件(读:module.processing.view 或 module.inventory.view —— 本页的门已经是加工)──────────
    const maintIds = maintRaw.map((m) => m.id)
    const partRaw = maintIds.length
        ? (mustRows(await supabase.from('maintenance_part_issues')
                .select('id, maintenance_id, inbound_batch_id, kind, returns_issue_id, quantity, business_date, reason')
                .in('maintenance_id', maintIds).order('business_date', { ascending: false }), 'maintenance_part_issues') as {
                id: string; maintenance_id: string; inbound_batch_id: string; kind: string; returns_issue_id: string | null
                quantity: number; business_date: string; reason: string | null }[])
        : []
    // 批号与物料名是标签,跟着这一行走(常设决定 3)—— 但批次表的门是 module.inbound.view;读不到的那几批印「受限」,不印空
    const partBatchIds = [...new Set(partRaw.map((p) => p.inbound_batch_id))]
    const partBatchRows = partBatchIds.length
        ? mustRows(await supabase.from('inbound_batches_masked').select('id, code, unit, material_id').in('id', partBatchIds), 'inbound_batches_masked parts') as
            { id: string; code: string; unit: string; material_id: string }[]
        : []
    const partMatIds = [...new Set(partBatchRows.map((b) => b.material_id))]
    const partMatName = new Map((partMatIds.length
        ? mustRows(await supabase.from('materials').select('id, name').in('id', partMatIds), 'materials parts') as { id: string; name: string }[]
        : []).map((m) => [m.id, m.name]))
    const partBatches = new Map(partBatchRows.map((b) => [b.id, { ...b, materials: { name: partMatName.get(b.material_id) ?? '' } }]))
    // 金额:还挂着的数量 × 今天的落地单价 —— 与账一致,因为改价时出给保养那一份已进 6800。
    //   落地单价读 inbound_batch_valuation(它的取数体自己 require_permission('module.inventory.view'),并按 data.view_prices 遮蔽价格)。
    //   ★ 不调 inbound_batch_landed_unit_cost:那一支刻意没有授给 authenticated(zzz_function_grants.sql 写着为什么)—— 本刀第一稿就调了它,
    //     本地版式普查里三个看得见价格的克隆整页 500,看不见价格的仓库克隆照常 200。所以金额只给【两个码都持】的人。
    const canSeeValue = canSeePrices && canSeeStock
    const landed = new Map<string, number | null>()
    if (canSeeValue && partBatchIds.length) {
        for (const v of mustRows(await supabase.from('inbound_batch_valuation').select('id, landed_unit_cost').in('id', partBatchIds),
                                 'inbound_batch_valuation parts') as { id: string; landed_unit_cost: number | null }[]) {
            landed.set(v.id, v.landed_unit_cost === null ? null : Number(v.landed_unit_cost))
        }
    }
    const recordLabel = new Map(maintRows.map((m) => [m.id, `${m.performed_on} · ${t('equipment.kind.' + m.kind)} · ${m.description}`]))
    const partRows: PartIssueRow[] = partRaw.filter((p) => p.kind === 'issue').map((p) => {
        const rets = partRaw.filter((r) => r.returns_issue_id === p.id)
        const returned = rets.reduce((a, r) => a + Number(r.quantity), 0)
        const outstanding = Number(p.quantity) - returned
        const b = partBatches.get(p.inbound_batch_id)
        const cost = landed.get(p.inbound_batch_id)
        return {
            id: p.id,
            issuedOn: formatDate(p.business_date, locale),
            record: recordLabel.get(p.maintenance_id) ?? '—',
            batch: b ? `${b.code} · ${b.materials?.name ?? ''}` : t('common.restricted'),
            unit: b?.unit ?? '',
            quantity: Number(p.quantity),
            returned,
            outstanding,
            returns: rets.map((r) => `${formatDate(r.business_date, locale)} · ${Number(r.quantity)} · ${r.reason ?? ''}`),
            value: !canSeeValue ? null
                : cost === null || cost === undefined ? t('equipment.parts.noCost')
                : formatAmount(Math.round(outstanding * cost * 100) / 100, baseCurrency),
        }
    })
    // 出库表单从 spare_part_stock 挑批(可用数量 · 有没有价 · 在不在暂扣 —— 与 issue_spare_parts 同一组判据);读不到 = null
    const partStock: PartStock[] | null = canSeeStock
        ? (mustRows(await supabase.from('spare_part_stock')
                .select('inbound_batch_id, batch_code, material_name, unit, available_qty, priced, hold_ncr_code')
                .order('batch_code'), 'spare_part_stock') as {
                inbound_batch_id: string; batch_code: string; material_name: string; unit: string; available_qty: number
                priced: boolean; hold_ncr_code: string | null }[])
            .map((s) => ({ batchId: s.inbound_batch_id, label: `${s.batch_code} · ${s.material_name}`, unit: s.unit,
                           available: Number(s.available_qty), priced: s.priced, holdNcr: s.hold_ncr_code }))
        : null
    const partRecords = maintRaw.map((m) => ({
        id: m.id, label: recordLabel.get(m.id) ?? m.id, capitalised: m.capitalised || m.capitalised_expense_id !== null,
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
    const words = relRow ? reliabilityWords(relRow, t) : null

    return (
        <ListPage
            maxWidth="max-w-4xl"
            breadcrumb={<Link href="/operation/equipment" className="hover:underline text-sm app-link">{t('common.back')}</Link>}
            title={t('equipment.page.detailTitle')}
            intro={t('equipment.page.detailIntro')}
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

            {/* ── MES-7a-1(Q5):可靠性 —— 这台机器的整段记录;分母说出来,读不出数的时候说为什么 ───────────── */}
            <section className="mt-6 border border-gray-200 rounded-lg p-3" data-section="reliability">
                <div className="flex flex-wrap items-baseline justify-between gap-2">
                    <h2 className="">{t('equipment.rel.title')}</h2>
                    <Link href={`/operation/equipment/reliability`} className="app-link hover:underline text-sm">{t('equipment.rel.allMachines')}</Link>
                </div>
                {words ? (
                    <div className="mt-2 text-sm space-y-1">
                        <p><span className="text-[color:var(--brand-muted-text)]">{t('equipment.rel.colMtbf')}:</span> <span data-rel="mtbf">{words.mtbf}</span></p>
                        <p><span className="text-[color:var(--brand-muted-text)]">{t('equipment.rel.colMttr')}:</span> <span data-rel="mttr">{words.mttr}</span></p>
                        <p className="text-xs text-[color:var(--brand-muted-text)]">{words.denominator}</p>
                        {words.gaps && <p className="text-xs text-amber-700" data-rel="gaps">{words.gaps}</p>}
                    </div>
                ) : (
                    <p className="mt-2 text-sm text-[color:var(--brand-muted-text)]">{t('equipment.rel.notEquipment')}</p>
                )}
            </section>

            <div className="mt-8">
                <ServiceIntervalPanel
                    assetId={id}
                    rows={statusRows}
                    acquisitionDate={usage.acquisition_date ? formatDate(usage.acquisition_date, locale) : '—'}
                    runsBeforeAcquisition={runsBeforeAcquisition}
                    kgSinceAcquisition={Number(usage.input_kg)}
                    canEdit={canRecord} />
                <MaintenancePanel
                    assetId={id}
                    rows={maintRows}
                    employees={employees}
                    suppliers={suppliers}
                    expenses={expenses}
                    downtimes={linkableDowntimes}
                    canEdit={canRecord}
                    canCapitalise={canFinanceEdit}
                    showCapitalise={false}
                    inServiceDate={usage.in_service_date ? formatDate(usage.in_service_date, locale) : null}
                    capitalisePct={Number(settings?.capitalise_pct_of_cost ?? 0)}
                    capitaliseFloor={Number(settings?.capitalise_floor_base ?? 0)}
                    equipmentCostBase={costBase}
                    baseCurrency={baseCurrency}
                    currencies={[]} />
                <SparePartsPanel
                    assetId={id}
                    records={partRecords}
                    stock={partStock}
                    rows={partRows}
                    canIssue={canIssueParts}
                    canSeeValue={canSeeValue} />
                <DowntimePanel
                    assetId={id}
                    rows={downRows}
                    canEdit={canRecord}
                    locale={locale}
                    causes={causes} />
                {!canHr && <p className="text-xs text-[color:var(--brand-muted-text)]">{t('equipment.maint.employeesRestricted')}</p>}
            </div>

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

            {/* AUDIT-TRAIL-1b-1(Q22):保养 · 停机(原因与来源)· 保养周期 · 交接班里提到的停机;资产卡自己的改动只给财务看(M3 · Q4) */}
            {/* MES-7b-1(MES-7b Step 0 §3):点名这台机器的事故(安全查看码;别人看见「受限」)—— MTBF 照旧只数停机 */}
            <LinkedIncidents kind="machine" id={id} />

            <AuditTrail subject="equipment" id={id} show={trailCount((await searchParams).trail)} />
        </ListPage>
    )
}
