'use client'

// MES-8b-1(2026-10-17,MES-0 Q82 · MES-8 Step 0 Q14 · Q28,Tim):合规包的八节 —— 实时预览与冻下来的那一份画的是同一个形状(packTypes.ts)。
//   这里一个数都不算:每一格都是 payload 里那一格。事故一节【没有】受伤的细节(payload 里本来就没有);第 7、8 节没给值时照原样说
//   「not yet set (V26 / V27)」,第 8 节旁边放这个月的投入与各形态产出 —— 不算效率(Q28)。
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import type { CompliancePackPayload, PackBalanceLine, PackRollforward, PackCategory, PackCeilingCheck, PackIncident,
    PackEnvResult, PackInspection, PackOpenFinding } from './packTypes'

const qty = (n: number | null | undefined) => (n === null || n === undefined ? '—' : new Intl.NumberFormat('en-US', { maximumFractionDigits: 3 }).format(Number(n)))

export default function PackSections({ p }: { p: CompliancePackPayload }) {
    const t = useTranslations()
    const lineLabel: Record<string, string> = {
        input: t('compliancePacks.line.input'), output: t('compliancePacks.line.output'), loss: t('compliancePacks.line.loss'),
        remainder: t('compliancePacks.line.remainder'), pass_through: t('compliancePacks.line.passThrough'),
        reversed: t('compliancePacks.line.reversed'), not_kg: t('compliancePacks.line.notKg'),
    }
    const catState: Record<PackCategory['state'], string> = {
        licence_not_in_force: t('compliancePacks.cat.licenceNotInForce'), ceiling_not_set: t('compliancePacks.cat.ceilingNotSet'),
        above_ceiling: t('compliancePacks.cat.aboveCeiling'), within_ceiling: t('compliancePacks.cat.withinCeiling'),
    }
    const deadline: Record<PackIncident['deadline_state'], string> = {
        not_reportable: t('compliancePacks.inc.notReportable'), submitted: t('compliancePacks.inc.submitted'), not_set: t('compliancePacks.inc.deadlineNotSet'),
        cannot_compute: t('compliancePacks.inc.deadlineCannotCompute'), computed: t('compliancePacks.inc.deadlineComputed'),
    }
    const judgement: Record<PackEnvResult['judgement'], string> = {
        exceeds: t('compliancePacks.env.exceeds'), within: t('compliancePacks.env.within'), not_judged: t('compliancePacks.env.notJudged'),
    }
    const yes = t('compliancePacks.yes'), no = t('compliancePacks.no')

    const balCols: Column<PackBalanceLine & { k: string }>[] = [
        { key: 'scope', header: t('compliancePacks.bal.colScope'), priority: true,
          render: (r) => (r.scope === 'plant' ? t('compliancePacks.bal.plant') : (r.operation_type_code ?? t('compliancePacks.bal.noOperation'))) },
        { key: 'line', header: t('compliancePacks.bal.colLine'), priority: true, render: (r) => lineLabel[r.line] ?? r.line },
        { key: 'key', header: t('compliancePacks.bal.colKey'), render: (r) => [r.line_key, r.basis].filter(Boolean).join(' · ') || '—' },
        { key: 'qty', header: t('compliancePacks.colKg'), align: 'right', priority: true, render: (r) => qty(r.qty_kg) },
        { key: 'runs', header: t('compliancePacks.bal.colRuns'), align: 'right', render: (r) => String(r.runs) },
    ]
    const rollCols: Column<PackRollforward & { k: string }>[] = [
        { key: 'unit', header: t('compliancePacks.roll.colUnit'), priority: true, render: (r) => r.unit },
        { key: 'opening', header: t('compliancePacks.roll.opening'), align: 'right', render: (r) => qty(r.opening) },
        { key: 'received', header: t('compliancePacks.roll.received'), align: 'right', render: (r) => qty(r.received) },
        { key: 'produced', header: t('compliancePacks.roll.produced'), align: 'right', render: (r) => qty(r.produced) },
        { key: 'consumed', header: t('compliancePacks.roll.consumed'), align: 'right', render: (r) => qty(r.consumed) },
        { key: 'sold', header: t('compliancePacks.roll.sold'), align: 'right', render: (r) => qty(r.sold) },
        { key: 'written_off', header: t('compliancePacks.roll.writtenOff'), align: 'right', render: (r) => qty(r.written_off) },
        { key: 'other', header: t('compliancePacks.roll.other'), align: 'right',
          render: (r) => qty(Number(r.adjusted) + Number(r.voided) + Number(r.issued_to_maintenance) + Number(r.moved)) },
        { key: 'closing', header: t('compliancePacks.roll.closing'), align: 'right', priority: true, render: (r) => qty(r.closing) },
    ]
    const catCols: Column<PackCategory & { k: string }>[] = [
        { key: 'cat', header: t('compliancePacks.lic.colCategory'), priority: true, render: (r) => `${r.category_code} · ${r.name_en}` },
        { key: 't', header: t('compliancePacks.lic.colTonnes'), align: 'right', priority: true, render: (r) => qty(r.tonnes) },
        { key: 'lim', header: t('compliancePacks.lic.colLimit'), align: 'right', render: (r) => qty(r.limit_tonnes) },
        { key: 'state', header: t('compliancePacks.lic.colState'), render: (r) => <span data-value={`category-${r.state}`}>{catState[r.state]}</span> },
    ]
    const checkCols: Column<PackCeilingCheck & { k: string }>[] = [
        { key: 'o', header: t('compliancePacks.lic.colOutcome'), priority: true, render: (r) => r.outcome },
        { key: 'c', header: t('compliancePacks.lic.colCategory'), render: (r) => r.category_code ?? '—' },
        { key: 'n', header: t('compliancePacks.lic.colChecks'), align: 'right', priority: true, render: (r) => String(r.checks) },
    ]
    const incCols: Column<PackIncident & { k: string }>[] = [
        { key: 'code', header: t('compliancePacks.inc.colCode'), priority: true, render: (r) => r.code },
        { key: 'kind', header: t('compliancePacks.inc.colKind'), render: (r) => r.kind_name_en ?? r.kind_code },
        { key: 'on', header: t('compliancePacks.inc.colOccurred'), render: (r) => r.occurred_on },
        { key: 'nea', header: t('compliancePacks.inc.colNea'), priority: true, render: (r) => (r.nea_reportable ? yes : no) },
        { key: 'notified', header: t('compliancePacks.inc.colNotified'), render: (r) => r.notified_on ?? '—' },
        { key: 'report', header: t('compliancePacks.inc.colReport'), render: (r) => r.report_submitted_on ?? '—' },
        { key: 'deadline', header: t('compliancePacks.inc.colDeadline'), render: (r) => (r.deadline_state === 'computed' ? (r.report_deadline ?? '—') : deadline[r.deadline_state]) },
        { key: 'closed', header: t('compliancePacks.inc.colClosed'), render: (r) => r.closed_on ?? '—' },
    ]
    const envCols: Column<PackEnvResult & { k: string }>[] = [
        { key: 'par', header: t('compliancePacks.env.colParameter'), priority: true, render: (r) => r.parameter_name_en ?? r.parameter_code },
        { key: 'pt', header: t('compliancePacks.env.colPoint'), render: (r) => r.sample_point },
        { key: 'on', header: t('compliancePacks.env.colSampled'), render: (r) => r.sampled_on },
        { key: 'v', header: t('compliancePacks.env.colValue'), align: 'right', priority: true, render: (r) => `${qty(r.value)} ${r.unit}` },
        { key: 'lim', header: t('compliancePacks.env.colLimit'), align: 'right',
          render: (r) => (r.limit_value === null ? t('compliancePacks.env.noLimit') : `${r.limit_basis === 'min' ? '≥' : '≤'} ${qty(r.limit_value)}`) },
        { key: 'j', header: t('compliancePacks.env.colJudgement'), priority: true,
          render: (r) => <span data-value={`judgement-${r.judgement}`}>{judgement[r.judgement]}{r.superseded ? ` · ${t('compliancePacks.env.superseded')}` : ''}</span> },
        { key: 'inc', header: t('compliancePacks.env.colIncident'), render: (r) => r.incident_code ?? '—' },
    ]
    const insCols: Column<PackInspection & { k: string }>[] = [
        { key: 'code', header: t('compliancePacks.ins.colCode'), priority: true, render: (r) => r.code },
        { key: 'tpl', header: t('compliancePacks.ins.colChecklist'), render: (r) => `${r.template_code} · ${r.template_name}` },
        { key: 'on', header: t('compliancePacks.ins.colInspected'), render: (r) => r.inspected_on },
        { key: 'res', header: t('compliancePacks.ins.colResults'), priority: true,
          render: (r) => t('compliancePacks.ins.results', { pass: String(r.passed), fail: String(r.failed), na: String(r.not_applicable) }) },
        { key: 'cor', header: t('compliancePacks.ins.colCorrection'), render: (r) => r.corrected_by ?? r.corrects ?? '—' },
    ]
    const findCols: Column<PackOpenFinding & { k: string }>[] = [
        { key: 'run', header: t('compliancePacks.ins.colCode'), priority: true, render: (r) => r.run_code },
        { key: 'item', header: t('compliancePacks.ins.colItem'), render: (r) => r.item ?? '—' },
        { key: 'act', header: t('compliancePacks.ins.colAction'), priority: true, render: (r) => r.corrective_action },
        { key: 'due', header: t('compliancePacks.ins.colDue'), render: (r) => r.due_date ?? '—' },
        { key: 'days', header: t('compliancePacks.ins.colDaysOpen'), align: 'right', render: (r) => String(r.days_open_at_month_end) },
    ]
    const k = <T,>(rows: T[]) => rows.map((r, i) => ({ ...r, k: String(i) }))
    const lic = p.licence.in_force

    return (
        <div data-section="compliance-pack">
            <section className="mb-6" data-section="pack-balance">
                <h2 className="mb-2">{t('compliancePacks.s1')}</h2>
                <DataTable rows={k(p.processing_balance)} columns={balCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} empty={t('compliancePacks.bal.none')} />
            </section>
            <section className="mb-6" data-section="pack-rollforward">
                <h2 className="mb-2">{t('compliancePacks.s2')}</h2>
                <DataTable rows={k(p.stock_rollforward)} columns={rollCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} empty={t('compliancePacks.roll.none')} />
            </section>
            <section className="mb-6" data-section="pack-licence">
                <h2 className="mb-2">{t('compliancePacks.s3')}</h2>
                <p className="text-sm mb-2" data-value="licence-in-force">
                    {lic ? t('compliancePacks.lic.inForce', { no: lic.cert_no, from: lic.valid_from, until: lic.valid_until, limit: qty(lic.approved_storage_limit_tonnes) })
                         : t('compliancePacks.lic.noneInForce')}
                </p>
                <DataTable rows={k(p.licence.on_hand_by_category)} columns={catCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} empty={t('compliancePacks.lic.noCategories')} />
                <p className="text-xs text-[color:var(--brand-muted-text)] mt-2 mb-3">
                    {t('compliancePacks.lic.uncategorised', { t: qty(p.licence.uncategorised_tonnes) })}
                    {p.licence.movements_without_business_date > 0 && <>{' '}{t('compliancePacks.lic.undated', { n: String(p.licence.movements_without_business_date) })}</>}
                </p>
                <h3 className="mb-2 text-sm font-medium">{t('compliancePacks.lic.checksTitle')}</h3>
                <DataTable rows={k(p.licence.ceiling_checks)} columns={checkCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} empty={t('compliancePacks.lic.noChecks')} />
            </section>
            <section className="mb-6" data-section="pack-incidents">
                <h2 className="mb-1">{t('compliancePacks.s4')}</h2>
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('compliancePacks.inc.noInjuryNote')}</p>
                <DataTable rows={k(p.incidents)} columns={incCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} empty={t('compliancePacks.inc.none')} />
            </section>
            <section className="mb-6" data-section="pack-environmental">
                <h2 className="mb-2">{t('compliancePacks.s5')}</h2>
                <DataTable rows={k(p.environmental)} columns={envCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} empty={t('compliancePacks.env.none')} />
            </section>
            <section className="mb-6" data-section="pack-inspections">
                <h2 className="mb-2">{t('compliancePacks.s6')}</h2>
                <DataTable rows={k(p.inspections.done)} columns={insCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} empty={t('compliancePacks.ins.none')} />
                <h3 className="mt-4 mb-2 text-sm font-medium">{t('compliancePacks.ins.openTitle')}</h3>
                <DataTable rows={k(p.inspections.findings_open_at_month_end)} columns={findCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} empty={t('compliancePacks.ins.noneOpen')} />
            </section>
            <section className="mb-6" data-section="pack-nea-return">
                <h2 className="mb-2">{t('compliancePacks.s7')}</h2>
                <p className="text-sm" data-value={`nea-return-${p.nea_return.state}`}>
                    {p.nea_return.state === 'not_set' ? t('compliancePacks.neaNotSet')
                        : t('compliancePacks.neaSet', { format: p.nea_return.format ?? '', frequency: p.nea_return.frequency ?? '' })}
                </p>
            </section>
            <section className="mb-6" data-section="pack-eu-efficiency">
                <h2 className="mb-2">{t('compliancePacks.s8')}</h2>
                <p className="text-sm mb-1" data-value={`eu-efficiency-${p.eu_efficiency.state}`}>
                    {p.eu_efficiency.state === 'not_set' ? t('compliancePacks.euNotSet')
                        : t('compliancePacks.euSet', { method: p.eu_efficiency.method ?? '', targets: p.eu_efficiency.targets ?? '' })}
                </p>
                <p className="text-xs text-[color:var(--brand-muted-text)]">
                    {t('compliancePacks.euMasses', {
                        input: qty(p.eu_efficiency.masses.input_kg),
                        outputs: p.eu_efficiency.masses.outputs.length === 0 ? '—'
                            : p.eu_efficiency.masses.outputs.map((o) => `${o.form ?? '—'} ${qty(o.qty_kg)}`).join(' · '),
                    })}
                </p>
            </section>
        </div>
    )
}
