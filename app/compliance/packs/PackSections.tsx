'use client'

// MES-8b-1(2026-10-17,MES-0 Q82 · MES-8 Step 0 Q14 · Q28,Tim):合规包的八节 —— 实时预览与冻下来的那一份画的是同一个形状(packTypes.ts)。
//   这里一个数都不算:每一格都是 payload 里那一格。事故一节【没有】受伤的细节(payload 里本来就没有);第 7、8 节没给值时照原样说
//   「not yet set (V26 / V27)」,第 8 节旁边放这个月的投入与各形态产出 —— 不算效率(Q28)。
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xDate, xInt, xNum, xText } from '@/lib/export/cells'
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

    const balCols: ExportableColumn<PackBalanceLine & { k: string }>[] = [
        { key: 'scope', header: t('compliancePacks.bal.colScope'), priority: true,
          render: (r) => (r.scope === 'plant' ? t('compliancePacks.bal.plant') : (r.operation_type_code ?? t('compliancePacks.bal.noOperation'))),
          exportAs: (r) => xText(r.scope === 'plant' ? t('compliancePacks.bal.plant') : (r.operation_type_code ?? t('compliancePacks.bal.noOperation'))) },
        { key: 'line', header: t('compliancePacks.bal.colLine'), priority: true, render: (r) => lineLabel[r.line] ?? r.line, exportAs: (r) => xText(lineLabel[r.line] ?? r.line) },
        { key: 'key', header: t('compliancePacks.bal.colKey'), render: (r) => [r.line_key, r.basis].filter(Boolean).join(' · ') || '—', exportAs: (r) => xText([r.line_key, r.basis].filter(Boolean).join(' · ') || '—') },
        { key: 'qty', header: t('compliancePacks.colKg'), align: 'right', priority: true, render: (r) => qty(r.qty_kg), exportAs: (r) => xNum(r.qty_kg) },
        { key: 'runs', header: t('compliancePacks.bal.colRuns'), align: 'right', render: (r) => String(r.runs), exportAs: (r) => xInt(r.runs) },
    ]
    const rollCols: ExportableColumn<PackRollforward & { k: string }>[] = [
        { key: 'unit', header: t('compliancePacks.roll.colUnit'), priority: true, render: (r) => r.unit, exportAs: (r) => xText(r.unit) },
        { key: 'opening', header: t('compliancePacks.roll.opening'), align: 'right', render: (r) => qty(r.opening), exportAs: (r) => xNum(r.opening) },
        { key: 'received', header: t('compliancePacks.roll.received'), align: 'right', render: (r) => qty(r.received), exportAs: (r) => xNum(r.received) },
        { key: 'produced', header: t('compliancePacks.roll.produced'), align: 'right', render: (r) => qty(r.produced), exportAs: (r) => xNum(r.produced) },
        { key: 'consumed', header: t('compliancePacks.roll.consumed'), align: 'right', render: (r) => qty(r.consumed), exportAs: (r) => xNum(r.consumed) },
        { key: 'sold', header: t('compliancePacks.roll.sold'), align: 'right', render: (r) => qty(r.sold), exportAs: (r) => xNum(r.sold) },
        { key: 'written_off', header: t('compliancePacks.roll.writtenOff'), align: 'right', render: (r) => qty(r.written_off), exportAs: (r) => xNum(r.written_off) },
        { key: 'other', header: t('compliancePacks.roll.other'), align: 'right',
          render: (r) => qty(Number(r.adjusted) + Number(r.voided) + Number(r.issued_to_maintenance) + Number(r.moved)),
          exportAs: (r) => xNum(Number(r.adjusted) + Number(r.voided) + Number(r.issued_to_maintenance) + Number(r.moved)) },
        { key: 'closing', header: t('compliancePacks.roll.closing'), align: 'right', priority: true, render: (r) => qty(r.closing), exportAs: (r) => xNum(r.closing) },
    ]
    const catCols: ExportableColumn<PackCategory & { k: string }>[] = [
        { key: 'cat', header: t('compliancePacks.lic.colCategory'), priority: true, render: (r) => `${r.category_code} · ${r.name_en}`, exportAs: (r) => xText(`${r.category_code} · ${r.name_en}`) },
        { key: 't', header: t('compliancePacks.lic.colTonnes'), align: 'right', priority: true, render: (r) => qty(r.tonnes), exportAs: (r) => xNum(r.tonnes) },
        { key: 'lim', header: t('compliancePacks.lic.colLimit'), align: 'right', sortValue: (r) => r.limit_tonnes, render: (r) => qty(r.limit_tonnes), exportAs: (r) => (r.limit_tonnes === null ? xText('—') : xNum(r.limit_tonnes)) },
        { key: 'state', header: t('compliancePacks.lic.colState'), render: (r) => <span data-value={`category-${r.state}`}>{catState[r.state]}</span>, exportAs: (r) => xText(catState[r.state]) },
    ]
    const checkCols: ExportableColumn<PackCeilingCheck & { k: string }>[] = [
        { key: 'o', header: t('compliancePacks.lic.colOutcome'), priority: true, render: (r) => r.outcome, exportAs: (r) => xText(r.outcome) },
        { key: 'c', header: t('compliancePacks.lic.colCategory'), sortValue: (r) => r.category_code, render: (r) => r.category_code ?? '—', exportAs: (r) => xText(r.category_code ?? '—') },
        { key: 'n', header: t('compliancePacks.lic.colChecks'), align: 'right', priority: true, render: (r) => String(r.checks), exportAs: (r) => xInt(r.checks) },
    ]
    const incCols: ExportableColumn<PackIncident & { k: string }>[] = [
        { key: 'code', header: t('compliancePacks.inc.colCode'), priority: true, render: (r) => r.code, exportAs: (r) => xText(r.code) },
        { key: 'kind', header: t('compliancePacks.inc.colKind'), render: (r) => r.kind_name_en ?? r.kind_code, exportAs: (r) => xText(r.kind_name_en ?? r.kind_code) },
        { key: 'on', header: t('compliancePacks.inc.colOccurred'), render: (r) => r.occurred_on, exportAs: (r) => xDate(r.occurred_on) },
        { key: 'nea', header: t('compliancePacks.inc.colNea'), priority: true, render: (r) => (r.nea_reportable ? yes : no), exportAs: (r) => xText(r.nea_reportable ? yes : no) },
        { key: 'notified', header: t('compliancePacks.inc.colNotified'), sortValue: (r) => r.notified_on, render: (r) => r.notified_on ?? '—', exportAs: (r) => (r.notified_on ? xDate(r.notified_on) : xText('—')) },
        { key: 'report', header: t('compliancePacks.inc.colReport'), sortValue: (r) => r.report_submitted_on, render: (r) => r.report_submitted_on ?? '—', exportAs: (r) => (r.report_submitted_on ? xDate(r.report_submitted_on) : xText('—')) },
        // TABLE-FEATURES-1 Q9:期限一格可能是日期,也可能是一句状态 —— 按日期排,说状态的那几行排最后
        { key: 'deadline', header: t('compliancePacks.inc.colDeadline'), sortValue: (r) => (r.deadline_state === 'computed' ? r.report_deadline : null), render: (r) => (r.deadline_state === 'computed' ? (r.report_deadline ?? '—') : deadline[r.deadline_state]),
          exportAs: (r) => (r.deadline_state === 'computed' ? (r.report_deadline ? xDate(r.report_deadline) : xText('—')) : xText(deadline[r.deadline_state])) },
        { key: 'closed', header: t('compliancePacks.inc.colClosed'), sortValue: (r) => r.closed_on, render: (r) => r.closed_on ?? '—', exportAs: (r) => (r.closed_on ? xDate(r.closed_on) : xText('—')) },
    ]
    const envCols: ExportableColumn<PackEnvResult & { k: string }>[] = [
        { key: 'par', header: t('compliancePacks.env.colParameter'), priority: true, render: (r) => r.parameter_name_en ?? r.parameter_code, exportAs: (r) => xText(r.parameter_name_en ?? r.parameter_code) },
        { key: 'pt', header: t('compliancePacks.env.colPoint'), render: (r) => r.sample_point, exportAs: (r) => xText(r.sample_point) },
        { key: 'on', header: t('compliancePacks.env.colSampled'), render: (r) => r.sampled_on, exportAs: (r) => xDate(r.sampled_on) },
        { key: 'v', header: t('compliancePacks.env.colValue'), align: 'right', priority: true, render: (r) => `${qty(r.value)} ${r.unit}`, exportAs: (r) => xNum(r.value, 'qty', r.unit) },
        { key: 'lim', header: t('compliancePacks.env.colLimit'), align: 'right',
          render: (r) => (r.limit_value === null ? t('compliancePacks.env.noLimit') : `${r.limit_basis === 'min' ? '≥' : '≤'} ${qty(r.limit_value)}`),
          // TABLE-FEATURES-1 Q9:按限值那个数排(没有限值的排最后);方向符号不参与比较
          sortValue: (r) => r.limit_value,
          // 限值前面那个 ≥ / ≤ 是限值的一部分 —— 一格写不下「方向 + 数」,照屏幕那串字导出
          exportAs: (r) => xText(r.limit_value === null ? t('compliancePacks.env.noLimit') : `${r.limit_basis === 'min' ? '≥' : '≤'} ${qty(r.limit_value)}`) },
        { key: 'j', header: t('compliancePacks.env.colJudgement'), priority: true,
          render: (r) => <span data-value={`judgement-${r.judgement}`}>{judgement[r.judgement]}{r.superseded ? ` · ${t('compliancePacks.env.superseded')}` : ''}</span>,
          exportAs: (r) => xText(judgement[r.judgement] + (r.superseded ? ` · ${t('compliancePacks.env.superseded')}` : '')) },
        { key: 'inc', header: t('compliancePacks.env.colIncident'), sortValue: (r) => r.incident_code, render: (r) => r.incident_code ?? '—', exportAs: (r) => xText(r.incident_code ?? '—') },
    ]
    const insCols: ExportableColumn<PackInspection & { k: string }>[] = [
        { key: 'code', header: t('compliancePacks.ins.colCode'), priority: true, render: (r) => r.code, exportAs: (r) => xText(r.code) },
        { key: 'tpl', header: t('compliancePacks.ins.colChecklist'), render: (r) => `${r.template_code} · ${r.template_name}`, exportAs: (r) => xText(`${r.template_code} · ${r.template_name}`) },
        { key: 'on', header: t('compliancePacks.ins.colInspected'), render: (r) => r.inspected_on, exportAs: (r) => xDate(r.inspected_on) },
        { key: 'res', header: t('compliancePacks.ins.colResults'), priority: true,
          render: (r) => t('compliancePacks.ins.results', { pass: String(r.passed), fail: String(r.failed), na: String(r.not_applicable) }),
          exportAs: (r) => xText(t('compliancePacks.ins.results', { pass: String(r.passed), fail: String(r.failed), na: String(r.not_applicable) })) },
        { key: 'cor', header: t('compliancePacks.ins.colCorrection'), render: (r) => r.corrected_by ?? r.corrects ?? '—', exportAs: (r) => xText(r.corrected_by ?? r.corrects ?? '—') },
    ]
    const findCols: ExportableColumn<PackOpenFinding & { k: string }>[] = [
        { key: 'run', header: t('compliancePacks.ins.colCode'), priority: true, render: (r) => r.run_code, exportAs: (r) => xText(r.run_code) },
        { key: 'item', header: t('compliancePacks.ins.colItem'), render: (r) => r.item ?? '—', exportAs: (r) => xText(r.item ?? '—') },
        { key: 'act', header: t('compliancePacks.ins.colAction'), priority: true, render: (r) => r.corrective_action, exportAs: (r) => xText(r.corrective_action) },
        { key: 'due', header: t('compliancePacks.ins.colDue'), sortValue: (r) => r.due_date, render: (r) => r.due_date ?? '—', exportAs: (r) => (r.due_date ? xDate(r.due_date) : xText('—')) },
        { key: 'days', header: t('compliancePacks.ins.colDaysOpen'), align: 'right', render: (r) => String(r.days_open_at_month_end), exportAs: (r) => xInt(r.days_open_at_month_end) },
    ]
    const k = <T,>(rows: T[]) => rows.map((r, i) => ({ ...r, k: String(i) }))
    // TABLE-FEATURES-1(Tim 2026-10-25 Q9):每一节都是合规包 payload 里那一节的【全部】行 —— 在浏览器里排。
    //   比较值默认取导出值;导出成「—」文字的那几列另给 sortValue(空值排最后,不当成一个字)。
    // TABLE-EXPORT-3a(Tim 2026-10-23 Q1,C 的报表体之一):八节里的每一张表各一对导出,About 表写明是哪一个月的合规包。
    //   格子照 payload 原样(这里一个数都不算);限值、检查结果这类「几样东西拼成的一句话」照屏幕那串字导出。
    const about: Array<[string, string]> = [[t('table.export.aboutPeriod'), p.month]]
    const lic = p.licence.in_force

    return (
        <div data-section="compliance-pack">
            <section className="mb-6" data-section="pack-balance">
                <h2 className="mb-2">{t('compliancePacks.s1')}</h2>
                <DataTable rows={k(p.processing_balance)} columns={balCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} sorting={{ mode: 'client', coverage: 'complete' }} empty={t('compliancePacks.bal.none')}
                    exportSpec={{ name: 'compliance-pack-balance', title: t('compliancePacks.s1'), aboutExtra: about }} />
            </section>
            <section className="mb-6" data-section="pack-rollforward">
                <h2 className="mb-2">{t('compliancePacks.s2')}</h2>
                <DataTable rows={k(p.stock_rollforward)} columns={rollCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} sorting={{ mode: 'client', coverage: 'complete' }} empty={t('compliancePacks.roll.none')}
                    exportSpec={{ name: 'compliance-pack-rollforward', title: t('compliancePacks.s2'), aboutExtra: about }} />
            </section>
            <section className="mb-6" data-section="pack-licence">
                <h2 className="mb-2">{t('compliancePacks.s3')}</h2>
                <p className="text-sm mb-2" data-value="licence-in-force">
                    {lic ? t('compliancePacks.lic.inForce', { no: lic.cert_no, from: lic.valid_from, until: lic.valid_until, limit: qty(lic.approved_storage_limit_tonnes) })
                         : t('compliancePacks.lic.noneInForce')}
                </p>
                <DataTable rows={k(p.licence.on_hand_by_category)} columns={catCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} sorting={{ mode: 'client', coverage: 'complete' }} empty={t('compliancePacks.lic.noCategories')}
                    exportSpec={{ name: 'compliance-pack-licence-categories', title: t('compliancePacks.s3'), aboutExtra: about }} />
                <p className="text-xs text-[color:var(--brand-muted-text)] mt-2 mb-3">
                    {t('compliancePacks.lic.uncategorised', { t: qty(p.licence.uncategorised_tonnes) })}
                    {p.licence.movements_without_business_date > 0 && <>{' '}{t('compliancePacks.lic.undated', { n: String(p.licence.movements_without_business_date) })}</>}
                </p>
                <h3 className="mb-2 text-sm font-medium">{t('compliancePacks.lic.checksTitle')}</h3>
                <DataTable rows={k(p.licence.ceiling_checks)} columns={checkCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} sorting={{ mode: 'client', coverage: 'complete' }} empty={t('compliancePacks.lic.noChecks')}
                    exportSpec={{ name: 'compliance-pack-ceiling-checks', title: t('compliancePacks.lic.checksTitle'), aboutExtra: about }} />
            </section>
            <section className="mb-6" data-section="pack-incidents">
                <h2 className="mb-1">{t('compliancePacks.s4')}</h2>
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('compliancePacks.inc.noInjuryNote')}</p>
                <DataTable rows={k(p.incidents)} columns={incCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} sorting={{ mode: 'client', coverage: 'complete' }} empty={t('compliancePacks.inc.none')}
                    exportSpec={{ name: 'compliance-pack-incidents', title: t('compliancePacks.s4'), aboutExtra: about }} />
            </section>
            <section className="mb-6" data-section="pack-environmental">
                <h2 className="mb-2">{t('compliancePacks.s5')}</h2>
                <DataTable rows={k(p.environmental)} columns={envCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} sorting={{ mode: 'client', coverage: 'complete' }} empty={t('compliancePacks.env.none')}
                    exportSpec={{ name: 'compliance-pack-environmental', title: t('compliancePacks.s5'), aboutExtra: about }} />
            </section>
            <section className="mb-6" data-section="pack-inspections">
                <h2 className="mb-2">{t('compliancePacks.s6')}</h2>
                <DataTable rows={k(p.inspections.done)} columns={insCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} sorting={{ mode: 'client', coverage: 'complete' }} empty={t('compliancePacks.ins.none')}
                    exportSpec={{ name: 'compliance-pack-inspections', title: t('compliancePacks.s6'), aboutExtra: about }} />
                <h3 className="mt-4 mb-2 text-sm font-medium">{t('compliancePacks.ins.openTitle')}</h3>
                <DataTable rows={k(p.inspections.findings_open_at_month_end)} columns={findCols} rowKey={(r) => r.k} phone={{ mode: 'columns' }} sorting={{ mode: 'client', coverage: 'complete' }} empty={t('compliancePacks.ins.noneOpen')}
                    exportSpec={{ name: 'compliance-pack-open-findings', title: t('compliancePacks.ins.openTitle'), aboutExtra: about }} />
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
