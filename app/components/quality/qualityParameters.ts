// app/components/quality/qualityParameters.ts
// MES-6b-1(2026-10-15,V17;MES-6b Step 0 Q8):质量验收限的【参数】—— moisture_pct(化验自己那一列水分)或 assay_indicators 的一个码。
//   名字:水分是一句消息(quality.param.moisture_pct),指标读字典自己的名字(按读者语言,停用的照样读得出 —— D5)。单位跟着参数:
//   水分是 %,指标是字典里那一格。合同页的选单、报告页的判定、批次页的判定清单都从这里拿,于是同一个参数在三处是同一个名字。
// 【真源在库里】contract_quality_limits 的 parameter / indicator 那一对 CHECK / 外键;这里只把字典读出来给人看。
import type { SupabaseClient } from '@supabase/supabase-js'
import { loadIndicatorDefs, indicatorName, type IndicatorDef } from './AssayIndicators'

export const MOISTURE = 'moisture_pct'

export type ParameterOption = { value: string; label: string; unit: string }

type T = (key: string, params?: Record<string, string>) => string

/** 选单:水分在前,其后是还能新选的指标(字典顺序)。 */
export function parameterOptions(defs: IndicatorDef[], locale: string, t: T): ParameterOption[] {
    return [
        { value: MOISTURE, label: t('quality.param.moisture_pct'), unit: '%' },
        ...defs.filter((d) => d.is_active).map((d) => ({ value: d.code, label: indicatorName(d, locale), unit: d.unit })),
    ]
}

/** 一个参数码 → 它的名字(带单位)。字典里没有的码原样返回(读不到 ≠ 没有这个码)。defs 要读【全部】(停用的也要读得出名字 —— D5)。 */
export function parameterLabeller(defs: IndicatorDef[], locale: string, t: T): (code: string) => string {
    const byCode = new Map(defs.map((d) => [d.code, d]))
    return (code: string) => {
        if (code === MOISTURE) return `${t('quality.param.moisture_pct')} (%)`
        const d = byCode.get(code)
        return d ? `${indicatorName(d, locale)} (${d.unit})` : code
    }
}

/** 同上,自己读字典。 */
export async function qualityParameterLabeller(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    supabase: SupabaseClient<any, any, any>, locale: string, t: T,
): Promise<(code: string) => string> {
    return parameterLabeller(await loadIndicatorDefs(supabase, false), locale, t)
}
