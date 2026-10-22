import 'server-only'

// TABLE-EXPORT-1(Tim 2026-10-22 Q2):盘点单登记簿的【一份】读取 —— 页面与导出路由共用。
// 页面取一页(.range),导出路由翻页取全(lib/export/serverRows.ts);两者走同一个 select、同一个排序、
// 同一个「库里的行 → 表的行」映射,于是导出不可能比屏幕多一列或多一种口径。
// 排序在 created_at 之后补一个 id —— 翻页取全要求一个【唯一】的次序(同一刻建的两张单不再随机互换)。

import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatTimestamp } from '@/lib/format'
import { formatAuditStamp } from '@/lib/dates'
import type { createClient } from '@/lib/supabase/server'
import { stocktakeStatusLabelKey } from './status'
import type { StocktakeRow } from './StocktakesTable'

type ServerSupabase = Awaited<ReturnType<typeof createClient>>

// 匹配总数
export function stocktakeCount(supabase: ServerSupabase) {
    return supabase
        .from('stocktakes')
        .select('id', { count: 'exact', head: true })
        .is('deleted_at', null)
}

export function stocktakePage(supabase: ServerSupabase, from: number, to: number) {
    return supabase
        .from('stocktakes')
        .select('id, code, status, started_at, posted_at, notes')
        .is('deleted_at', null)
        .order('created_at', { ascending: false })
        .order('id', { ascending: true })
        .range(from, to)
}

type StocktakeDbRow = NonNullable<Awaited<ReturnType<typeof stocktakePage>>['data']>[number]

export async function shapeStocktakeRows(rows: StocktakeDbRow[]): Promise<StocktakeRow[]> {
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    // 状态标签(未知值回退原样)
    const statusLabel = (v: string | null) => {
        const k = stocktakeStatusLabelKey(v)
        return k ? t(k) : v ?? '—'
    }

    return rows.map((r) => ({
        id: r.id,
        code: r.code,
        statusLabel: statusLabel(r.status),
        // 时间戳按 locale 格式化在服务端做完 —— dateLocale 不过 RSC 边界
        startedLabel: formatAuditStamp(r.started_at),
        postedLabel: r.posted_at ? formatTimestamp(r.posted_at, dateLocale) : null,
        notes: r.notes ?? '—',
        // TABLE-EXPORT-1:导出用的原始时刻(Excel 里是真日期,按新加坡时间)
        startedAt: r.started_at,
        postedAt: r.posted_at,
    }))
}
