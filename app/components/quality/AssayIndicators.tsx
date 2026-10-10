// app/components/quality/AssayIndicators.tsx
// ════════════════════════════════════════════════════════════════════════════
// MES-6a-2(2026-10-10,MES-0 3.5b · 3.5c · 3.5e;MES-6a Step 0 Q3 · Q4,Tim)· 化验上的指标:残粉 · 箔纯度 · 粒径 D10 / D50 / D90
// ════════════════════════════════════════════════════════════════════════════
// 【两种用法】
//   assayId  —— 化验详情页:这一份化验上记了哪些指标(值原样、单位是那个指标自己的)。
//   batch    —— 批次页:这一批的化验上【最近记下的】每个指标(按化验日期、再按编号取最新一份)—— 不是批次上的一份副本(Q3:没有副本),
//               是从化验行现读的;每个值说出它出自哪一份化验。
// 【没有判定】Q3:没有限、没有"合格 / 不合格"—— 限(V17)按合同,随质量冻结排在 MES-6b。这里只印数。
// 【谁看得见】assay_result_indicators 的读策略跟着化验的父批次(进料 / 产出查看码);页面的门已经问过那个码。
// 【名字】字典自己的(name_en / name_zh,按读者语言);停用的照样读得出名字(D5:停用只管新选)。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getLocale, getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { formatDate } from '@/lib/dates'
import { plainDecimal } from '@/lib/substances'
import type { SupabaseClient } from '@supabase/supabase-js'

export type IndicatorDef = { code: string; name_en: string; name_zh: string; unit: string; is_active: boolean }

/** 指标的定义。activeOnly = 表单(只给还能新选的);展示读全部(D5)。顺序是字典的 sort_order。 */
export async function loadIndicatorDefs(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    supabase: SupabaseClient<any, any, any>, activeOnly: boolean,
): Promise<IndicatorDef[]> {
    let q = supabase.from('assay_indicators').select('code, name_en, name_zh, unit, is_active').order('sort_order')
    if (activeOnly) q = q.eq('is_active', true)
    return mustRows(await q, 'assay_indicators') as unknown as IndicatorDef[]
}

export function indicatorName(d: IndicatorDef, locale: string): string {
    return locale === 'zh' ? d.name_zh : d.name_en
}

type ValueRow = { assay_result_id: string; indicator: string; value: number }

export default async function AssayIndicators(props: { assayId: string } | { kind: 'inbound' | 'output'; batchId: string }) {
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const defs = await loadIndicatorDefs(supabase, false)
    const defOf = new Map(defs.map((d) => [d.code, d]))
    const order = new Map(defs.map((d, i) => [d.code, i]))
    // % 贴着数(与含量的 "20.5%" 同一种写法);别的单位(µm)隔一个空格
    const valueText = (r: ValueRow) => { const u = defOf.get(r.indicator)?.unit ?? ''; return u === '%' ? `${plainDecimal(r.value)}%` : `${plainDecimal(r.value)} ${u}`.trim() }
    const nameOf = (code: string) => { const d = defOf.get(code); return d ? indicatorName(d, locale) : code }

    if ('assayId' in props) {
        const rows = (mustRows(await supabase.from('assay_result_indicators').select('assay_result_id, indicator, value')
            .eq('assay_result_id', props.assayId), 'assay_result_indicators') as unknown as ValueRow[])
            .sort((a, b) => (order.get(a.indicator) ?? 99) - (order.get(b.indicator) ?? 99))
        return (
            <section className="mt-6 mb-6" data-panel="assay-indicators">
                <h2 className="mb-1">{t('assay.indicators.title')}</h2>
                {rows.length === 0 ? (
                    <p className="text-sm text-[color:var(--brand-muted-text)]">{t('assay.indicators.noneOnAssay')}</p>
                ) : (
                    <dl className="grid grid-cols-1 sm:grid-cols-2 gap-x-8 gap-y-1 text-sm">
                        {rows.map((r) => (
                            <div key={r.indicator} className="flex flex-wrap gap-x-2">
                                <dt className="text-[color:var(--brand-muted-text)]">{nameOf(r.indicator)}:</dt>
                                <dd>{valueText(r)}</dd>
                            </div>
                        ))}
                    </dl>
                )}
                <p className="mt-1 text-xs text-[color:var(--brand-muted-text)]">{t('assay.indicators.noLimitNote')}</p>
            </section>
        )
    }

    // ── 批次页:这一批的化验上最近记下的每个指标 ──
    const col = props.kind === 'inbound' ? 'inbound_batch_id' : 'output_batch_id'
    const assays = mustRows(await supabase.from('assay_results').select('id, code, assay_date')
        .eq(col, props.batchId).is('deleted_at', null), 'assay_results') as { id: string; code: string; assay_date: string }[]
    const assayOf = new Map(assays.map((a) => [a.id, a]))
    const values = assays.length === 0 ? [] : mustRows(await supabase.from('assay_result_indicators')
        .select('assay_result_id, indicator, value').in('assay_result_id', assays.map((a) => a.id)), 'assay_result_indicators') as unknown as ValueRow[]
    // 每个指标取最新那一份:化验日期大的在前,同一天编号大的在前(编号按年无洞、单调 —— 排序确定)
    const latest = new Map<string, ValueRow>()
    for (const v of values) {
        const cur = latest.get(v.indicator)
        const a = assayOf.get(v.assay_result_id)!, c = cur ? assayOf.get(cur.assay_result_id)! : null
        if (!c || a.assay_date > c.assay_date || (a.assay_date === c.assay_date && a.code > c.code)) latest.set(v.indicator, v)
    }
    const rows = [...latest.values()].sort((a, b) => (order.get(a.indicator) ?? 99) - (order.get(b.indicator) ?? 99))
    const base = props.kind === 'inbound' ? `/inbound/${props.batchId}/assays/` : `/output/${props.batchId}/assays/`
    return (
        <section className="mt-6" data-panel="batch-indicators">
            <h3 className="mb-1">{t('assay.indicators.latestTitle')}</h3>
            {rows.length === 0 ? (
                <p className="text-sm text-[color:var(--brand-muted-text)]">{t('assay.indicators.noneOnBatch')}</p>
            ) : (
                <dl className="grid grid-cols-1 sm:grid-cols-2 gap-x-8 gap-y-1 text-sm">
                    {rows.map((r) => {
                        const a = assayOf.get(r.assay_result_id)!
                        return (
                            <div key={r.indicator} className="flex flex-wrap gap-x-2">
                                <dt className="text-[color:var(--brand-muted-text)]">{nameOf(r.indicator)}:</dt>
                                <dd>
                                    {valueText(r)}{' '}
                                    <span className="text-xs text-[color:var(--brand-muted-text)]">
                                        · <Link href={base + a.id} className="app-link hover:underline">{a.code}</Link> · {formatDate(a.assay_date, locale)}
                                    </span>
                                </dd>
                            </div>
                        )
                    })}
                </dl>
            )}
        </section>
    )
}
