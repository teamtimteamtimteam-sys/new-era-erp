// app/compliance/packs/[id]/pdf/CompliancePackDocument.tsx
// MES-8b-1(2026-10-17,MES-0 Q82 · MES-8 Step 0 Q14 · Q16 · Q28,Tim):合规包的版面。
//
// ★【它印的是【冻下来的 payload】,不是现算的】★ 八节的每一格都来自 compliance_packs.payload —— 冻结那一刻抄下来的。几个月后重打这一版,
//   纸上还是当时那些数(对账单与分析证书的同一条)。事故一节【没有】受伤的细节:payload 里本来就没有。
// ★【一律英文】(Q16)—— 收件人(NEA、审计、买家)不是这套系统的用户。措辞只有一处来源:messages/en.ts 的 compliancePacks.doc.*
//   (renderPack.ts 显式取英文那一份),不在这里硬写。
// ★ 一条 fontFamily 都没有 —— 加粗一律 fontWeight:'bold'(PDF-1;scripts/check-pdf-font-stack.mjs 拦着)。
//   限值的方向写成单词(max / min),不写 ≤ / ≥:那两个字不一定在 PDF 的字体子集里(MES8A-CUSTOMER-STATEMENT-ARROW-GLYPH 那一课)。
// ★ 每一节的标题带 minPresenceAhead —— 版式勘察量到第 8 节的标题孤零零落在第 1 页底、正文在第 2 页;标题下面放不下 48pt 的内容就整个挪到下一页。
import { Document, Page, Text, View, StyleSheet } from '@react-pdf/renderer'
import { docStyles, DocumentLetterhead, DocumentFooter, NoSignatureNote } from '@/app/components/pdf/DocumentChrome'
import { BRAND } from '@/app/components/pdf/theme'
import type { LetterheadCompany } from '@/app/components/CompanyLetterhead'
import type { CompliancePackPayload } from '../../packTypes'

export type CompliancePackDocData = {
    code: string
    month: string
    period_start: string
    period_end: string
    frozen_at: string
    locked_before: string
    superseded: boolean
    company: LetterheadCompany
    p: CompliancePackPayload
    noSignature: string
    t: Record<string, string>
}

const styles = StyleSheet.create({
    meta: { fontSize: 9, marginBottom: 10 },
    sectionTitle: { fontSize: 10, fontWeight: 'bold', marginTop: 12, marginBottom: 4, color: BRAND.text },
    row: { flexDirection: 'row' },
    th: { fontWeight: 'bold', backgroundColor: BRAND.accent, padding: 3, fontSize: 8 },
    td: { padding: 3, borderBottomWidth: 0.5, borderBottomColor: BRAND.hairline, fontSize: 8 },
    right: { textAlign: 'right' },
    line: { fontSize: 9, marginBottom: 2 },
    note: { fontSize: 8, color: BRAND.muted, marginTop: 4 },
    voidMark: { position: 'absolute', top: 260, left: 90, fontSize: 60, color: '#d33', opacity: 0.25 },
})

const qty = (n: number | null | undefined) => (n === null || n === undefined ? '-' : new Intl.NumberFormat('en-US', { maximumFractionDigits: 3 }).format(Number(n)))

/** 一张简单的表:列宽(百分比)、表头、每一行的格子;空表印一句说明。 */
function Grid({ widths, head, rows, empty, right = [] }: {
    widths: string[]; head: string[]; rows: string[][]; empty: string; right?: number[]
}) {
    if (rows.length === 0) return <Text style={styles.note}>{empty}</Text>
    return (
        <View>
            <View style={styles.row}>
                {head.map((h, i) => <Text key={i} style={[styles.th, right.includes(i) ? styles.right : {}, { width: widths[i] }] as never}>{h}</Text>)}
            </View>
            {rows.map((r, j) => (
                <View key={j} style={styles.row} wrap={false}>
                    {r.map((c, i) => <Text key={i} style={[styles.td, right.includes(i) ? styles.right : {}, { width: widths[i] }] as never}>{c}</Text>)}
                </View>
            ))}
        </View>
    )
}

export default function CompliancePackDocument({ data: d }: { data: CompliancePackDocData }) {
    const t = d.t
    const p = d.p
    const lineLabel = (l: string) => t['line_' + l] ?? l
    const lic = p.licence.in_force
    return (
        <Document title={d.code}>
            <Page size="A4" style={docStyles.page}>
                {d.superseded ? <Text style={styles.voidMark}>SUPERSEDED</Text> : null}
                <DocumentLetterhead company={d.company} />
                <Text style={docStyles.title}>{t.title}</Text>
                <Text style={styles.meta}>{d.code} · {t.month} {d.month} · {d.period_start} {t.periodSeparator} {d.period_end}</Text>
                <Text style={styles.note}>{t.frozenNote}</Text>

                <Text style={styles.sectionTitle} minPresenceAhead={48}>{t.s1}</Text>
                <Grid widths={['22%', '20%', '30%', '16%', '12%']} head={[t.colScope, t.colLine, t.colKey, t.colKg, t.colRuns]} right={[3, 4]} empty={t.noBalance}
                    rows={p.processing_balance.map((b) => [b.scope === 'plant' ? t.plant : (b.operation_type_code ?? t.noOperation), lineLabel(b.line),
                        [b.line_key, b.basis].filter(Boolean).join(' · ') || '-', qty(b.qty_kg), String(b.runs)])} />

                <Text style={styles.sectionTitle} minPresenceAhead={48}>{t.s2}</Text>
                <Grid widths={['8%', '11%', '11%', '11%', '11%', '11%', '11%', '13%', '13%']} right={[1, 2, 3, 4, 5, 6, 7, 8]} empty={t.noRollforward}
                    head={[t.colUnit, t.opening, t.received, t.produced, t.consumed, t.sold, t.writtenOff, t.other, t.closing]}
                    rows={p.stock_rollforward.map((r) => [r.unit, qty(r.opening), qty(r.received), qty(r.produced), qty(r.consumed), qty(r.sold), qty(r.written_off),
                        qty(Number(r.adjusted) + Number(r.voided) + Number(r.issued_to_maintenance) + Number(r.moved)), qty(r.closing)])} />

                <Text style={styles.sectionTitle} minPresenceAhead={48}>{t.s3}</Text>
                <Text style={styles.line}>
                    {lic ? `${t.licenceInForce}: ${lic.cert_no}${lic.issuing_body ? ` (${lic.issuing_body})` : ''} · ${lic.valid_from} ${t.periodSeparator} ${lic.valid_until} · ${t.approvedLimit} ${qty(lic.approved_storage_limit_tonnes)} t`
                         : t.noLicence}
                </Text>
                <Grid widths={['40%', '18%', '18%', '24%']} head={[t.colCategory, t.colTonnes, t.colLimit, t.colState]} right={[1, 2]} empty={t.noCategories}
                    rows={p.licence.on_hand_by_category.map((c) => [`${c.category_code} · ${c.name_en}`, qty(c.tonnes), qty(c.limit_tonnes), t['cat_' + c.state] ?? c.state])} />
                <Text style={styles.note}>{t.uncategorised} {qty(p.licence.uncategorised_tonnes)} t</Text>
                <Text style={styles.line}>{t.checksTitle}</Text>
                <Grid widths={['45%', '35%', '20%']} head={[t.colOutcome, t.colCategory, t.colChecks]} right={[2]} empty={t.noChecks}
                    rows={p.licence.ceiling_checks.map((c) => [c.outcome, c.category_code ?? '-', String(c.checks)])} />

                <Text style={styles.sectionTitle} minPresenceAhead={48}>{t.s4}</Text>
                <Text style={styles.note}>{t.noInjuryNote}</Text>
                <Grid widths={['14%', '18%', '12%', '9%', '12%', '12%', '12%', '11%']} empty={t.noIncidents}
                    head={[t.colCode, t.colKind, t.colOccurred, t.colNea, t.colNotified, t.colReport, t.colDeadline, t.colClosed]}
                    rows={p.incidents.map((i) => [i.code, i.kind_name_en ?? i.kind_code, i.occurred_on, i.nea_reportable ? t.yes : t.no, i.notified_on ?? '-',
                        i.report_submitted_on ?? '-', i.deadline_state === 'computed' ? (i.report_deadline ?? '-') : (t['deadline_' + i.deadline_state] ?? i.deadline_state),
                        i.closed_on ?? '-'])} />

                <Text style={styles.sectionTitle} minPresenceAhead={48}>{t.s5}</Text>
                <Grid widths={['20%', '14%', '12%', '14%', '14%', '14%', '12%']} right={[3, 4]} empty={t.noEnvironmental}
                    head={[t.colParameter, t.colPoint, t.colSampled, t.colValue, t.colLimit, t.colJudgement, t.colIncident]}
                    rows={p.environmental.map((e) => [e.parameter_name_en ?? e.parameter_code, e.sample_point, e.sampled_on, `${qty(e.value)} ${e.unit}`,
                        e.limit_value === null ? t.noLimit : `${e.limit_basis ?? ''} ${qty(e.limit_value)}`,
                        (t['judgement_' + e.judgement] ?? e.judgement) + (e.superseded ? ` · ${t.superseded}` : ''), e.incident_code ?? '-'])} />

                <Text style={styles.sectionTitle} minPresenceAhead={48}>{t.s6}</Text>
                <Grid widths={['16%', '34%', '14%', '22%', '14%']} empty={t.noInspections}
                    head={[t.colCode, t.colChecklist, t.colInspected, t.colResults, t.colCorrection]}
                    rows={p.inspections.done.map((r) => [r.code, `${r.template_code} · ${r.template_name}`, r.inspected_on,
                        `${t.pass} ${r.passed} · ${t.fail} ${r.failed} · ${t.na} ${r.not_applicable}`, r.corrected_by ?? r.corrects ?? '-'])} />
                <Text style={styles.line}>{t.openTitle}</Text>
                <Grid widths={['16%', '26%', '32%', '14%', '12%']} right={[4]} empty={t.noneOpen}
                    head={[t.colCode, t.colItem, t.colAction, t.colDue, t.colDaysOpen]}
                    rows={p.inspections.findings_open_at_month_end.map((f) => [f.run_code, f.item ?? '-', f.corrective_action, f.due_date ?? '-', String(f.days_open_at_month_end)])} />

                <Text style={styles.sectionTitle} minPresenceAhead={48}>{t.s7}</Text>
                <Text style={styles.line}>{p.nea_return.state === 'not_set' ? t.neaNotSet : `${t.neaFormat}: ${p.nea_return.format ?? ''} · ${t.neaFrequency}: ${p.nea_return.frequency ?? ''} · ${t.neaNotProduced}`}</Text>

                <Text style={styles.sectionTitle} minPresenceAhead={48}>{t.s8}</Text>
                <Text style={styles.line}>{p.eu_efficiency.state === 'not_set' ? t.euNotSet : `${t.euMethod}: ${p.eu_efficiency.method ?? ''} · ${t.euTargets}: ${p.eu_efficiency.targets ?? ''} · ${t.euNotComputed}`}</Text>
                <Text style={styles.note}>
                    {t.euMasses} {qty(p.eu_efficiency.masses.input_kg)} kg · {p.eu_efficiency.masses.outputs.length === 0 ? '-'
                        : p.eu_efficiency.masses.outputs.map((o) => `${o.form ?? '-'} ${qty(o.qty_kg)} kg`).join(' · ')}
                </Text>

                <Text style={styles.note}>{t.frozenAt} {d.frozen_at} · {t.lockedBefore} {d.locked_before}</Text>
                <NoSignatureNote text={d.noSignature} />
                <DocumentFooter code={d.code} />
            </Page>
        </Document>
    )
}
