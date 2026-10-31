// app/safety/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// SYSTEM-MAP-4(Tim 2026-10-29 第 16 条 · 2026-10-30 Q1)· ESG 概览 —— 这个模块此刻是什么状态
// ════════════════════════════════════════════════════════════════════════════
// 【四条陈述,Tim Q1 原样】每一条都横跨几张页面、没有一张页面单独说得出(docs/module-overview-basis.md 的判据):
//   ① 事故与巡检 —— 本月发生的事故、还开着的事故,与还开着(及逾期)的巡检发现。事故在「事故」页,发现在「巡检」页。
//   ② 环境超标 —— 今年的环境监测结果里有几条超标,超标的那几条挂的事故还有几起开着。结果在「环境监测」,事故在「事故」。
//   ③ 执照与供应商证书的到期 —— 公司执照(ESG › 公司执照)与供应商证书(采购 › 供应商 › 供应商证书)里已过期 / 快到期的张数。
//      状态由库里那一支判据算(certificate_expiry_status —— 提醒页与供应商证书总表读的同一支),这里不另写一份。
//   ④ 销毁证书 —— 已签发 · 待签发 · 已作废的张数;清单在「运营 › 进料 › COD」,每一张在它的批次页上。
// 【每一条按它自己的码】(Tim Q1:"each gated by its own code"):①② module.safety.view · ③ module.suppliers.view ·
//   ④ data.view_cod。先判码、再决定查不查 —— 进不去的那一条画具名的「受限」,不是一个空集读出来的零(D5)。
//   页面的门(注册表 /safety)是三者任一,所以一个只持其一的人进得来、看得见自己那一条。
// ★ ESG-2(Tim 2026-10-31 Q15 · E):再加五条,各按自己的码 —— ⑤ Scope 2(能耗强度页那一对码:财务或加工查看)· ⑥ 误工事故与频率
//   (module.safety.view 进得来,数要 data.view_health)· ⑦ 培训合规(module.hr.view)· ⑧ 制度登记簿(有员工档案的人都读得到 —— 行由视图裁)·
//   ⑨ 还开着的举报(读者自己的举报码:涉及 CCO 的那几件只算给持 data.view_whistleblowing_escalated 的人 —— 行谓词在库里,这里只数读到的)。
//   每一个数都是那一页同一支库函数 / 同一张视图的答案,这里不另算。
// 【手机(390px)】单列 max-w-3xl,与另外几张概览逐字同一个外壳。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN, allows } from '@/lib/modules'
import { getMyPermissions } from '@/lib/permissions'
import { mustRows } from '@/lib/db-helpers'
import { businessToday } from '@/lib/format'
import Figure from '@/app/components/overview/Figure'
import { readAll } from '@/lib/readAll'

const P_SAFETY = 'module.safety.view'
const P_SUPPLIERS = 'module.suppliers.view'
const P_COD = 'data.view_cod'
const P_HEALTH = 'data.view_health'
const P_HR = 'module.hr.view'
const P_WB = ['data.view_whistleblowing', 'data.view_whistleblowing_escalated'] as const

const none = { data: null, error: null }

export default async function EsgOverviewPage() {
    const denied = await requireFunction(FN.esgHome)
    if (denied) return denied

    const t = await getTranslations()
    const perms = await getMyPermissions()
    const supabase = await createClient()
    const asOf = businessToday()
    const monthStart = `${asOf.slice(0, 7)}-01`
    const yearStart = `${asOf.slice(0, 4)}-01-01`

    const canSafety = allows(P_SAFETY, perms)
    const canSuppliers = allows(P_SUPPLIERS, perms)
    const canCod = allows(P_COD, perms)
    const canEnergy = allows(FN.esgEnergy.permission, perms)
    const canHealth = allows(P_HEALTH, perms)
    const canHr = allows(P_HR, perms)
    const canWb = allows({ all: [], any: [...P_WB] }, perms)
    const thisYear = Number(asOf.slice(0, 4))
    const thisMonth = Number(asOf.slice(5, 7))

    const [incRes, findRes, envRes, licRes, typeRes, supRes, codRes] = await Promise.all([
        canSafety ? readAll(() => supabase.from('incident_rows').select('id, occurred_on, closed_at'), { label: 'incident_rows' }) : Promise.resolve(none),
        canSafety ? readAll(() => supabase.from('inspection_finding_rows').select('id, is_open, overdue'), { label: 'inspection_finding_rows' }) : Promise.resolve(none),
        canSafety ? readAll(() => supabase.from('environmental_result_rows').select('id, exceeds, incident_id, sampled_on').gte('sampled_on', yearStart), { label: 'environmental_result_rows' }) : Promise.resolve(none),
        canSuppliers ? supabase.from('company_compliance').select('id, cert_type_code, valid_until').is('deleted_at', null) : Promise.resolve(none),
        canSuppliers ? supabase.from('certificate_types').select('code, disposition, warn_lead_days') : Promise.resolve(none),
        canSuppliers ? readAll(() => supabase.from('supplier_certificate_status').select('id, status'), { label: 'supplier_certificate_status' }) : Promise.resolve(none),
        canCod ? readAll(() => supabase.from('certificates_of_destruction').select('id, status'), { label: 'certificates_of_destruction' }) : Promise.resolve(none),
    ])

    const [s2Res, rateRes, covRes, polRes, wbRes] = await Promise.all([
        canEnergy ? supabase.rpc('esg_scope2_monthly', { p_year: thisYear }) : Promise.resolve(none),   // unpaged-ok: 恒为 12 行(一年的 12 个月,esg_scope2_monthly 的形状)
        canSafety ? supabase.rpc('esg_safety_rates', { p_year: thisYear }) : Promise.resolve(none),     // unpaged-ok: 至多 13 行(12 个月 + 年初至今那一行)
        canHr ? readAll(() => supabase.rpc('esg_training_coverage'), { label: 'esg_training_coverage', key: 'required_training_id' }) : Promise.resolve(none),
        readAll(() => supabase.from('company_policy_rows').select('id, is_current, review_overdue'), { label: 'company_policy_rows' }),
        canWb ? readAll(() => supabase.from('whistleblowing_report_rows').select('id, status'), { label: 'whistleblowing_report_rows' }) : Promise.resolve(none),
    ])

    // ── ⑤ Scope 2(年初至今,按天摊)──────────────────────────────────────────
    const s2 = canEnergy ? (mustRows(s2Res as never, 'esg_scope2_monthly') as { month: string; kwh: number | string; tco2: number | string | null; factor_missing: boolean; bills: number }[])
        .filter((m) => Number(String(m.month).slice(5, 7)) <= thisMonth) : []
    const s2Bills = s2.reduce((a, m) => a + m.bills, 0)
    const s2Missing = s2.some((m) => m.factor_missing)
    const s2T = s2.reduce((a, m) => a + Number(m.tco2 ?? 0), 0)
    const s2Kwh = s2.reduce((a, m) => a + Number(m.kwh), 0)
    const fmt = (v: number, d = 0) => new Intl.NumberFormat('en-US', { minimumFractionDigits: d, maximumFractionDigits: d }).format(v)

    // ── ⑥ 误工事故与频率(年初至今那一行)────────────────────────────────────
    const ytd = canSafety ? ((mustRows(rateRes as never, 'esg_safety_rates') as { month: string | null; hours_state: string; lti: number | null; days_lost: number | string | null; ltifr: number | string | null }[])
        .find((r) => r.month === null) ?? null) : null

    // ── ⑦ 培训合规 ──────────────────────────────────────────────────────────
    const cov = canHr ? mustRows(covRes as never, 'esg_training_coverage') as { applicable: number; valid: number; expiring: number; expired: number; missing: number }[] : []
    const covApplicable = cov.reduce((a, c) => a + c.applicable, 0)
    const covOk = cov.reduce((a, c) => a + c.valid + c.expiring, 0)

    // ── ⑧ 制度登记簿 ────────────────────────────────────────────────────────
    const pols = mustRows(polRes, 'company_policy_rows') as { id: string; is_current: boolean; review_overdue: boolean }[]
    const polCurrent = pols.filter((p) => p.is_current)

    // ── ⑨ 还开着的举报(读到的才数)────────────────────────────────────────
    const wbs = canWb ? mustRows(wbRes as never, 'whistleblowing_report_rows') as { id: string; status: string }[] : []

    // ── ① 事故与巡检 ────────────────────────────────────────────────────────
    const incidents = canSafety ? mustRows(incRes as never, 'incident_rows') as { id: string; occurred_on: string; closed_at: string | null }[] : []
    const findings = canSafety ? mustRows(findRes as never, 'inspection_finding_rows') as { id: string; is_open: boolean; overdue: boolean }[] : []
    const incThisMonth = incidents.filter((i) => i.occurred_on >= monthStart).length
    const incOpen = incidents.filter((i) => i.closed_at === null)
    const findOpen = findings.filter((f) => f.is_open).length
    const findOverdue = findings.filter((f) => f.is_open && f.overdue).length

    // ── ② 环境超标 ──────────────────────────────────────────────────────────
    const env = canSafety ? mustRows(envRes as never, 'environmental_result_rows') as { id: string; exceeds: boolean | null; incident_id: string | null }[] : []
    const exceed = env.filter((r) => r.exceeds === true)
    const openIds = new Set(incOpen.map((i) => i.id))
    const exceedOpen = exceed.filter((r) => r.incident_id !== null && openIds.has(r.incident_id)).length

    // ── ③ 执照与供应商证书 ──────────────────────────────────────────────────
    //   公司执照的状态逐张问库里那一支判据(张数很小;今天线上 1 张)—— 不在这里再写一遍「过期 / 快到期」的比较。
    let licExpired = 0, licExpiring = 0, licTotal = 0
    let supExpired = 0, supExpiring = 0, supTotal = 0
    if (canSuppliers) {
        const lic = mustRows(licRes as never, 'company_compliance') as { id: string; cert_type_code: string; valid_until: string | null }[]
        const types = mustRows(typeRes as never, 'certificate_types') as { code: string; disposition: string; warn_lead_days: number }[]
        const statuses = await Promise.all(lic.map(async (l) => {
            const ty = types.find((x) => x.code === l.cert_type_code)
            // 外键保证这一行在;读不到就是读错了,不替它编一个 disposition
            if (!ty) throw new Error(`certificate_types 里没有 ${l.cert_type_code}`)
            const res = await supabase.rpc('certificate_expiry_status', {
                p_valid_until: l.valid_until as string, p_disposition: ty.disposition, p_warn_lead_days: ty.warn_lead_days,
            })
            if (res.error) throw new Error(`查询失败(certificate_expiry_status): ${res.error.message}`)
            return res.data as string
        }))
        licTotal = lic.length
        licExpired = statuses.filter((s) => s === 'expired').length
        licExpiring = statuses.filter((s) => s === 'expiring').length
        const sup = mustRows(supRes as never, 'supplier_certificate_status') as { id: string; status: string }[]
        supTotal = sup.length
        supExpired = sup.filter((s) => s.status === 'expired').length
        supExpiring = sup.filter((s) => s.status === 'expiring').length
    }

    // ── ④ 销毁证书 ──────────────────────────────────────────────────────────
    const cods = canCod ? mustRows(codRes as never, 'certificates_of_destruction') as { id: string; status: string }[] : []
    const codCount = (s: string) => cods.filter((c) => c.status === s).length

    const link = (href: string, key: string) => <Link href={href} className="hover:underline app-link">{t(key)}</Link>

    return (
        <div className="p-4 sm:p-8 max-w-3xl">
            <h1 className="mb-1" style={{ color: 'var(--brand-text)' }}>
                {t('nav.modFull.safety')}
            </h1>
            <p className="text-sm mb-6 max-w-2xl" style={{ color: 'var(--brand-muted-text)' }}>
                {t('overview.intro')}
            </p>

            {/* ── ① 事故与巡检 ─────────────────────────────────────────── */}
            <Figure
                title={t('esg.overview.safetyTitle')}
                basis={{ asOf, source: t('esg.overview.safetySource'), spans: t('esg.overview.safetySpans') }}
                state={!canSafety ? { kind: 'restricted', permission: P_SAFETY } : { kind: 'ok' }}
                action={link(FN.safetyIncidents.href, FN.safetyIncidents.navKey)}
            >
                <p className="text-sm" style={{ color: 'var(--brand-text)' }} data-esg="safety">
                    {t('esg.overview.safetyLine', { month: incThisMonth, open: incOpen.length, findings: findOpen, overdue: findOverdue })}
                </p>
            </Figure>

            {/* ── ② 环境超标 ───────────────────────────────────────────── */}
            <Figure
                title={t('esg.overview.envTitle')}
                basis={{ asOf, source: t('esg.overview.envSource', { year: asOf.slice(0, 4) }), spans: t('esg.overview.envSpans') }}
                state={!canSafety ? { kind: 'restricted', permission: P_SAFETY }
                    : env.length === 0 ? { kind: 'unanswerable', why: t('esg.overview.envNone', { year: asOf.slice(0, 4) }) }
                    : { kind: 'ok' }}
                action={link(FN.safetyEnvironment.href, FN.safetyEnvironment.navKey)}
            >
                <p className="text-sm" style={{ color: 'var(--brand-text)' }} data-esg="environment">
                    {t('esg.overview.envLine', { results: env.length, exceed: exceed.length, open: exceedOpen })}
                </p>
            </Figure>

            {/* ── ③ 执照与供应商证书 ───────────────────────────────────── */}
            <Figure
                title={t('esg.overview.certTitle')}
                basis={{ asOf, source: t('esg.overview.certSource'), spans: t('esg.overview.certSpans') }}
                state={!canSuppliers ? { kind: 'restricted', permission: P_SUPPLIERS }
                    : licTotal + supTotal === 0 ? { kind: 'unanswerable', why: t('esg.overview.certNone') }
                    : { kind: 'ok' }}
                action={<span className="flex flex-wrap gap-x-4">{link(FN.licences.href, FN.licences.navKey)}{link(FN.supplierCertificates.href, FN.supplierCertificates.navKey)}</span>}
            >
                <p className="text-sm" style={{ color: 'var(--brand-text)' }} data-esg="certificates">
                    {t('esg.overview.certLicences', { total: licTotal, expired: licExpired, expiring: licExpiring })}
                </p>
                <p className="text-sm mt-1" style={{ color: 'var(--brand-text)' }}>
                    {t('esg.overview.certSuppliers', { total: supTotal, expired: supExpired, expiring: supExpiring })}
                </p>
            </Figure>

            {/* ── ④ 销毁证书 ───────────────────────────────────────────── */}
            <Figure
                title={t('esg.overview.codTitle')}
                basis={{ asOf, source: t('esg.overview.codSource'), spans: t('esg.overview.codSpans') }}
                state={!canCod ? { kind: 'restricted', permission: P_COD }
                    : cods.length === 0 ? { kind: 'unanswerable', why: t('esg.overview.codNone') }
                    : { kind: 'ok' }}
                action={link(FN.codList.href, FN.codList.navKey)}
            >
                <p className="text-sm" style={{ color: 'var(--brand-text)' }} data-esg="cod">
                    {t('esg.overview.codLine', { issued: codCount('issued'), pending: codCount('pending'), voided: codCount('void') })}
                </p>
            </Figure>

            {/* ── ⑤ Scope 2 ────────────────────────────────────────────── */}
            <Figure
                title={t('esg.overview.scope2Title')}
                basis={{ asOf, source: t('esg.overview.scope2Source', { year: thisYear }), spans: t('esg.overview.scope2Spans') }}
                state={!canEnergy ? { kind: 'restricted', permission: 'module.finance.view' }
                    : s2Bills === 0 ? { kind: 'unanswerable', why: t('esg.overview.scope2None', { year: thisYear }) }
                    : s2Missing ? { kind: 'unanswerable', why: t('esg.overview.scope2FactorNotSet') }
                    : { kind: 'ok' }}
                action={link(FN.esgEnergy.href, FN.esgEnergy.navKey)}
            >
                <p className="text-sm" style={{ color: 'var(--brand-text)' }} data-esg="scope2">
                    {t('esg.overview.scope2Line', { t: fmt(s2T, 3), kwh: fmt(s2Kwh, 1) })}
                </p>
            </Figure>

            {/* ── ⑥ 误工事故与频率 ─────────────────────────────────────── */}
            <Figure
                title={t('esg.overview.ratesTitle')}
                basis={{ asOf, source: t('esg.overview.ratesSource', { year: thisYear }), spans: t('esg.overview.ratesSpans') }}
                state={!canSafety ? { kind: 'restricted', permission: P_SAFETY }
                    : !canHealth ? { kind: 'restricted', permission: P_HEALTH }
                    : { kind: 'ok' }}
                action={link(FN.esgRates.href, FN.esgRates.navKey)}
            >
                <p className="text-sm" style={{ color: 'var(--brand-text)' }} data-esg="rates">
                    {ytd && ytd.hours_state === 'complete'
                        ? t('esg.overview.ratesLine', { lti: ytd.lti ?? 0, days: fmt(Number(ytd.days_lost ?? 0), 1), rate: fmt(Number(ytd.ltifr ?? 0), 2) })
                        : t('esg.overview.ratesNoRate', { lti: ytd?.lti ?? 0, days: fmt(Number(ytd?.days_lost ?? 0), 1) })}
                </p>
            </Figure>

            {/* ── ⑦ 培训合规 ───────────────────────────────────────────── */}
            <Figure
                title={t('esg.overview.trainingTitle')}
                basis={{ asOf, source: t('esg.overview.trainingSource'), spans: t('esg.overview.trainingSpans') }}
                state={!canHr ? { kind: 'restricted', permission: P_HR }
                    : cov.length === 0 ? { kind: 'unanswerable', why: t('esg.overview.trainingNone') }
                    : { kind: 'ok' }}
                action={link(FN.esgTraining.href, FN.esgTraining.navKey)}
            >
                <p className="text-sm" style={{ color: 'var(--brand-text)' }} data-esg="training">
                    {t('esg.overview.trainingLine', {
                        trainings: cov.length, pct: covApplicable === 0 ? '—' : `${Math.round((covOk / covApplicable) * 1000) / 10}%`,
                        expiring: cov.reduce((a, c) => a + c.expiring, 0), expired: cov.reduce((a, c) => a + c.expired, 0), missing: cov.reduce((a, c) => a + c.missing, 0),
                    })}
                </p>
            </Figure>

            {/* ── ⑧ 制度登记簿 ─────────────────────────────────────────── */}
            <Figure
                title={t('esg.overview.policiesTitle')}
                basis={{ asOf, source: t('esg.overview.policiesSource'), spans: t('esg.overview.policiesSpans') }}
                state={polCurrent.length === 0 ? { kind: 'unanswerable', why: t('esg.overview.policiesNone') } : { kind: 'ok' }}
                action={link(FN.esgPolicies.href, FN.esgPolicies.navKey)}
            >
                <p className="text-sm" style={{ color: 'var(--brand-text)' }} data-esg="policies">
                    {t('esg.overview.policiesLine', { current: polCurrent.length, overdue: polCurrent.filter((p) => p.review_overdue).length })}
                </p>
            </Figure>

            {/* ── ⑨ 还开着的举报 ───────────────────────────────────────── */}
            <Figure
                title={t('esg.overview.wbTitle')}
                basis={{ asOf, source: t('esg.overview.wbSource'), spans: t('esg.overview.wbSpans') }}
                state={!canWb ? { kind: 'restricted', permission: P_WB[0] } : { kind: 'ok' }}
                action={link(FN.esgWhistleblowing.href, FN.esgWhistleblowing.navKey)}
            >
                <p className="text-sm" style={{ color: 'var(--brand-text)' }} data-esg="whistleblowing">
                    {t('esg.overview.wbLine', { open: wbs.filter((w) => w.status !== 'closed').length, total: wbs.length })}
                </p>
            </Figure>
        </div>
    )
}
