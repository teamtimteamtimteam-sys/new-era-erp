// lib/savedViews.ts —— TABLE-FEATURES-3(Tim 2026-10-25 Q3 · 2026-10-26 Q1–Q3):保存的视图的查询串,存与取两个方向。
// 纯算术,服务端(默认视图的跳转,lib/savedViewsServer.ts)与浏览器(存 / 打开,app/components/ui/saved-views.tsx)用同一份。
//
// 【存】地址里 ? 之后那一段,去掉【不属于"怎么看"】的键:翻页(page · <前缀>page)、一次性的提示与跳转来源
//   (trail · warn · k · set · error · ok)、以及"plain list"那个记号(view)。
//   ★ Q2:起止日期正好是当天的某个快捷区间 → 不存那两个日期,存 date_preset=<名>;手敲的日期照原样存。
// 【取】date_preset=<名> → 按【打开那一天】的那个区间写回起止两个键(区间由服务端按新加坡的今天算好传进来)。
//   名字认不得(以后改了名)→ 去掉它,等于不带日期 —— 不猜一个区间。
import type { DatePreset } from '@/lib/datePresets'

/** "plain list":地址里带着它,默认视图就不套用(Q3)。页面自己不读它。 */
export const PLAIN_LIST_PARAM = 'view'
export const PLAIN_LIST_VALUE = 'plain'
export const DATE_PRESET_PARAM = 'date_preset'

const NOT_A_VIEW = new Set(['trail', 'warn', 'k', 'set', 'error', 'ok', PLAIN_LIST_PARAM])

/** 一张带起止日期的列表交给视图的那三样:两个键名,与当天的四个区间。 */
export type ViewDates = { fromKey: string; toKey: string; presets: readonly DatePreset[] }

export function encodeViewQuery(search: string, dates?: ViewDates): string {
    const params = new URLSearchParams(search.startsWith('?') ? search.slice(1) : search)
    for (const k of [...params.keys()]) {
        if (NOT_A_VIEW.has(k) || k === 'page' || k.endsWith('_page')) params.delete(k)
    }
    if (dates) {
        const from = params.get(dates.fromKey), to = params.get(dates.toKey)
        const preset = dates.presets.find((p) => p.from === from && p.to === to)
        if (preset) {
            params.delete(dates.fromKey)
            params.delete(dates.toKey)
            params.set(DATE_PRESET_PARAM, preset.key)
        }
    }
    return params.toString()
}

export function resolveViewQuery(query: string, dates?: ViewDates): string {
    const params = new URLSearchParams(query)
    const name = params.get(DATE_PRESET_PARAM)
    if (name !== null) {
        params.delete(DATE_PRESET_PARAM)
        const preset = dates?.presets.find((p) => p.key === name)
        if (dates && preset) {
            params.set(dates.fromKey, preset.from)
            params.set(dates.toKey, preset.to)
        }
    }
    return params.toString()
}

/** 打开一个视图的地址。查询串为空时仍带上 plain 记号 —— 否则一个"什么都不筛"的视图会被默认视图顶掉。 */
export function viewHref(listKey: string, query: string, dates?: ViewDates): string {
    const q = resolveViewQuery(query, dates)
    return `${listKey}?${q || `${PLAIN_LIST_PARAM}=${PLAIN_LIST_VALUE}`}`
}

export type SavedView = { id: string; name: string; query: string; is_default: boolean }
