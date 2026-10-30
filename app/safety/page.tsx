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

    const [incRes, findRes, envRes, licRes, typeRes, supRes, codRes] = await Promise.all([
        canSafety ? readAll(() => supabase.from('incident_rows').select('id, occurred_on, closed_at'), { label: 'incident_rows' }) : Promise.resolve(none),
        canSafety ? readAll(() => supabase.from('inspection_finding_rows').select('id, is_open, overdue'), { label: 'inspection_finding_rows' }) : Promise.resolve(none),
        canSafety ? readAll(() => supabase.from('environmental_result_rows').select('id, exceeds, incident_id, sampled_on').gte('sampled_on', yearStart), { label: 'environmental_result_rows' }) : Promise.resolve(none),
        canSuppliers ? supabase.from('company_compliance').select('id, cert_type_code, valid_until').is('deleted_at', null) : Promise.resolve(none),
        canSuppliers ? supabase.from('certificate_types').select('code, disposition, warn_lead_days') : Promise.resolve(none),
        canSuppliers ? readAll(() => supabase.from('supplier_certificate_status').select('id, status'), { label: 'supplier_certificate_status' }) : Promise.resolve(none),
        canCod ? readAll(() => supabase.from('certificates_of_destruction').select('id, status'), { label: 'certificates_of_destruction' }) : Promise.resolve(none),
    ])

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
        </div>
    )
}
