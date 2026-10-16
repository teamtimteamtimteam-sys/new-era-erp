// app/safety/environment/page.tsx
// MES-7b-2(2026-10-16,MES-0 Q75;MES-7b Step 0 Q16 · Q17 · Q20,Tim):环境监测 —— 实验室结果对着它记下那一刻的限值(V20):超标 · 在限值之内 ·
//   不判定(那一刻没有限值);超标的那一条开的事故;更正关系。上面是记一条结果的表单,下面是结果,最底是这一页的审计记录(集合主语
//   safety_environment)。参数与限值在 /settings/dictionaries 里(一个都不引导 —— V20 由 NEA 执照给)。
//   【门】requireFunction(FN.safetyEnvironment) = module.safety.view;记要 module.safety.edit。【这一页不判任何事】判定读 environmental_result_rows。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows, mustOne } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import { formatDate } from '@/lib/dates'
import { judgementKey, limitBasisKey } from '../safetyTypes'
import EnvironmentForm, { type ParamOpt } from './EnvironmentForm'
import EnvironmentTable, { type EnvRow } from './EnvironmentTable'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const num = (v: number | string | null) => (v == null ? '' : String(Number(v)))

type R = {
    id: string; parameter_code: string; parameter_name_en: string; parameter_name_zh: string; sample_point: string; sampled_on: string
    laboratory_code: string; laboratory_name_en: string; laboratory_name_zh: string; report_reference: string; value: number; unit: string
    limit_value: number | null; limit_basis: string | null; judgement: string; incident_id: string | null; incident_code: string | null
    corrects_result_id: string | null; correction_reason: string | null; corrected_by_result_id: string | null
}

export default async function EnvironmentPage({ searchParams }: { searchParams: Promise<{ trail?: string | string[]; corrects?: string | string[] }> }) {
    const denied = await requireFunction(FN.safetyEnvironment)
    if (denied) return denied
    const t = await getTranslations()
    const locale = await getLocale()
    const sp = await searchParams
    const supabase = await createClient()

    const [resRes, parRes, labRes, canEdit] = await Promise.all([
        supabase.from('environmental_result_rows')
            .select('id, parameter_code, parameter_name_en, parameter_name_zh, sample_point, sampled_on, laboratory_code, laboratory_name_en, laboratory_name_zh, report_reference, value, unit, limit_value, limit_basis, judgement, incident_id, incident_code, corrects_result_id, correction_reason, corrected_by_result_id')
            .order('sampled_on', { ascending: false }).order('recorded_at', { ascending: false }).limit(300),
        supabase.from('environmental_parameters').select('code, name_en, name_zh, unit, limit_value, limit_basis, is_active').order('sort_order').order('code'),
        supabase.from('laboratories').select('code, name_en, name_zh, is_active').eq('is_active', true).order('sort_order'),
        can('module.safety.edit'),
    ])
    const results = mustRows(resRes, 'environmental_result_rows') as R[]
    const params = mustRows(parRes, 'environmental_parameters') as {
        code: string; name_en: string; name_zh: string; unit: string; limit_value: number | null; limit_basis: string | null; is_active: boolean }[]
    const labs = (mustRows(labRes, 'laboratories') as { code: string; name_en: string; name_zh: string }[])
        .map((l) => ({ id: l.code, label: locale === 'zh' ? l.name_zh : l.name_en }))
    const limitText = (v: number | null, basis: string | null, unit: string) =>
        v == null || !basis ? t('safety.environment.noLimit') : t('safety.environment.limit', { basis: t(limitBasisKey(basis)), value: num(v), unit })
    const paramOpts: ParamOpt[] = params.filter((p) => p.is_active).map((p) => ({
        code: p.code, label: locale === 'zh' ? p.name_zh : p.name_en, unit: p.unit,
        limit: p.limit_value == null || !p.limit_basis ? null : limitText(p.limit_value, p.limit_basis, p.unit),
    }))

    const correctsId = (Array.isArray(sp.corrects) ? sp.corrects[0] : sp.corrects) ?? ''
    let corrects: React.ComponentProps<typeof EnvironmentForm>['corrects'] = null
    if (correctsId && UUID.test(correctsId)) {
        const c = mustOne(await supabase.from('environmental_result_rows')
            .select('id, parameter_code, parameter_name_en, parameter_name_zh, sample_point, sampled_on, laboratory_code, value, unit, corrected_by_result_id')
            .eq('id', correctsId).maybeSingle(), 'environmental_result_rows') as {
            id: string; parameter_code: string; parameter_name_en: string; parameter_name_zh: string; sample_point: string; sampled_on: string
            laboratory_code: string; value: number; unit: string; corrected_by_result_id: string | null } | null
        if (c && !c.corrected_by_result_id) {
            corrects = { id: c.id, parameterCode: c.parameter_code, samplePoint: c.sample_point, sampledOn: c.sampled_on, laboratoryCode: c.laboratory_code,
                         label: `${locale === 'zh' ? c.parameter_name_zh : c.parameter_name_en} · ${c.sample_point} · ${formatDate(c.sampled_on, locale)} · ${num(c.value)} ${c.unit}` }
        }
    }

    const rows: EnvRow[] = results.map((r) => ({
        id: r.id,
        parameter: locale === 'zh' ? r.parameter_name_zh : r.parameter_name_en,
        samplePoint: r.sample_point,
        sampledOn: formatDate(r.sampled_on, locale),
        laboratory: locale === 'zh' ? r.laboratory_name_zh : r.laboratory_name_en,
        report: r.report_reference,
        value: `${num(r.value)} ${r.unit}`,
        limit: limitText(r.limit_value, r.limit_basis, r.unit),
        judgement: t(judgementKey(r.judgement)),
        judgementFlag: r.judgement as EnvRow['judgementFlag'],
        incidentId: r.incident_id, incidentCode: r.incident_code,
        note: r.corrected_by_result_id ? t('safety.environment.corrected') : r.corrects_result_id ? t('safety.environment.correction', { reason: r.correction_reason ?? '' }) : null,
        canCorrect: canEdit && !r.corrected_by_result_id,
    }))

    return (
        <ListPage
            title={t('safety.environment.title')}
            intro={t('safety.environment.intro')}
            state={{ kind: 'ok' }}
            notices={params.length === 0 ? (
                <div className="bg-amber-50 border border-amber-300 px-4 py-3 rounded mb-4 text-sm" data-notice="no-parameters">
                    {t('safety.environment.noParameters')}{' '}
                    <Link href="/settings/dictionaries" className="app-link hover:underline">{t('safety.environment.toDictionaries')}</Link>
                </div>
            ) : null}
        >
            <section data-section="record">
                <h2 className="mb-2">{corrects ? t('safety.environment.correctTitle') : t('safety.environment.recordTitle')}</h2>
                {paramOpts.length === 0
                    ? <p className="text-sm text-[color:var(--brand-muted-text)]">{t('safety.environment.noActiveParameters')}</p>
                    : <EnvironmentForm params={paramOpts} labs={labs} canEdit={canEdit} corrects={corrects} />}
            </section>
            <section className="mt-8" data-section="results">
                <h2 className="mb-1">{t('safety.environment.resultsTitle')}</h2>
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('safety.environment.resultsHint')}</p>
                <EnvironmentTable rows={rows} empty={t('safety.environment.noResults')} correctLabel={canEdit ? t('safety.environment.correct') : null} />
            </section>
            <AuditTrail subject="safety_environment" id="all" show={trailCount(sp.trail)} />
        </ListPage>
    )
}
