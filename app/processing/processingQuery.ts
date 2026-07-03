// app/processing/processingQuery.ts
// 加工单列表查询逻辑:日期区间(process_date)+ 排序 + 分页 + 软删除过滤。
// 端口自 inboundQuery,但精简 —— 本 cut 只做日期 + 分页,无搜索 / 状态筛选。
import { parseDateRange } from '@/lib/dateFilter'

// 允许排序的列白名单(只含本表列)。
export const PROCESSING_SORTABLE = ['process_date', 'created_at'] as const
export type ProcessingSortCol = (typeof PROCESSING_SORTABLE)[number]

export interface ProcessingListParams {
    dateFrom: string // '' 表示不按 process_date 起始过滤
    dateTo: string // '' 表示不按 process_date 结束过滤
    sort: ProcessingSortCol
    dir: 'asc' | 'desc'
}

export const PROCESSING_PAGE_SIZE = 20

export function parseProcessingPage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

export function parseProcessingListParams(sp: {
    date_from?: string
    date_to?: string
    sort?: string
    dir?: string
}): ProcessingListParams {
    const { dateFrom, dateTo } = parseDateRange(sp)
    const sort: ProcessingSortCol = (PROCESSING_SORTABLE as readonly string[]).includes(sp.sort ?? '')
        ? (sp.sort as ProcessingSortCol)
        : 'created_at'
    const dir: 'asc' | 'desc' = sp.dir === 'asc' ? 'asc' : 'desc'
    return { dateFrom, dateTo, sort, dir }
}

// supabase filter builder 的最小链式子集(避免引入其深泛型)。
interface ProcessingQueryChain {
    is(column: string, value: null): ProcessingQueryChain
    gte(column: string, value: string): ProcessingQueryChain
    lte(column: string, value: string): ProcessingQueryChain
    order(column: string, options: { ascending: boolean }): ProcessingQueryChain
}

// 套用 软删除过滤 / process_date 区间 / 排序。不做分页(列表页另行 .range())。
export function applyProcessingFilters<T>(query: T, params: ProcessingListParams): T {
    const { dateFrom, dateTo, sort, dir } = params
    let chain = query as unknown as ProcessingQueryChain
    chain = chain.is('deleted_at', null)
    if (dateFrom) chain = chain.gte('process_date', dateFrom)
    if (dateTo) chain = chain.lte('process_date', dateTo)
    chain = chain.order(sort, { ascending: dir === 'asc' })
    return chain as unknown as T
}
