import 'server-only'

// TABLE-EXPORT-2b-1(Tim 2026-10-22 TABLE-EXPORT-2 Q2):环境监测结果的【一份】读取 —— 页面与导出路由共用。
// 页面只画最近 ENV_SHOWN 条(从前是一句不说的 .limit(300)),表上方 RowCapNotice 说出「前 N 条,共 M 条」;
// 导出路由按同一条读取、同一个映射翻页取全(上限 50,000)。排序在采样日与记录时刻之后补 id —— 翻页要一个【唯一】的次序。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { formatDate } from '@/lib/dates'
import { getLocale, getTranslations } from '@/lib/i18n/server'
import { judgementKey, limitBasisKey } from '../safetyTypes'
import type { EnvRow } from './EnvironmentTable'

type Client = SupabaseClient<Database>

/** 页面画多少条 —— 与转换之前同一个数。 */
export const ENV_SHOWN = 300

export type EnvDbRow = {
    id: string; parameter_code: string; parameter_name_en: string; parameter_name_zh: string; sample_point: string; sampled_on: string
    laboratory_code: string; laboratory_name_en: string; laboratory_name_zh: string; report_reference: string; value: number; unit: string
    limit_value: number | null; limit_basis: string | null; judgement: string; incident_id: string | null; incident_code: string | null
    corrects_result_id: string | null; correction_reason: string | null; corrected_by_result_id: string | null
}

export const envNum = (v: number | string | null) => (v == null ? '' : String(Number(v)))

export function envCount(supabase: Client) {
    return supabase.from('environmental_result_rows').select('id', { count: 'exact', head: true })
}

export function envPage(supabase: Client, from: number, to: number) {
    return supabase
        .from('environmental_result_rows')
        .select('id, parameter_code, parameter_name_en, parameter_name_zh, sample_point, sampled_on, laboratory_code, laboratory_name_en, laboratory_name_zh, report_reference, value, unit, limit_value, limit_basis, judgement, incident_id, incident_code, corrects_result_id, correction_reason, corrected_by_result_id')
        .order('sampled_on', { ascending: false })
        .order('recorded_at', { ascending: false })
        .order('id', { ascending: true })
        .range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as EnvDbRow[] | null }))
}

/** `canEdit`:能不能更正(module.safety.edit)—— 只决定屏幕上那个链接,导出不用。 */
export async function shapeEnvRows(rows: EnvDbRow[], canEdit: boolean): Promise<EnvRow[]> {
    const [t, locale] = await Promise.all([getTranslations(), getLocale()])
    const limitText = (v: number | null, basis: string | null, unit: string) =>
        v == null || !basis ? t('safety.environment.noLimit') : t('safety.environment.limit', { basis: t(limitBasisKey(basis)), value: envNum(v), unit })
    return rows.map((r) => ({
        id: r.id,
        parameter: locale === 'zh' ? r.parameter_name_zh : r.parameter_name_en,
        samplePoint: r.sample_point,
        sampledOn: formatDate(r.sampled_on, locale),
        laboratory: locale === 'zh' ? r.laboratory_name_zh : r.laboratory_name_en,
        report: r.report_reference,
        value: `${envNum(r.value)} ${r.unit}`,
        sampledOnRaw: r.sampled_on, valueRaw: r.value, unit: r.unit,
        limit: limitText(r.limit_value, r.limit_basis, r.unit),
        judgement: t(judgementKey(r.judgement)),
        judgementFlag: r.judgement as EnvRow['judgementFlag'],
        incidentId: r.incident_id, incidentCode: r.incident_code,
        note: r.corrected_by_result_id ? t('safety.environment.corrected') : r.corrects_result_id ? t('safety.environment.correction', { reason: r.correction_reason ?? '' }) : null,
        canCorrect: canEdit && !r.corrected_by_result_id,
    }))
}
