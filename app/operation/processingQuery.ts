// app/operation/processingQuery.ts
// 加工单列表查询逻辑:日期区间(process_date)+ 排序 + 分页 + 软删除过滤。
// 端口自 inboundQuery,但精简 —— 本 cut 只做日期 + 分页,无搜索 / 状态筛选。
import { parseDateRange } from '@/lib/dateFilter'
import { parseListSort, applyListSort, type ListSort } from '@/lib/listSort'

// 允许排序的列白名单(只含本表列)。
// ★ TABLE-FEATURES-1(Tim 2026-10-25 Q9):列键 → `processing_runs` 上的列(lib/listSort.ts 的规矩)。
//   原来的两个键(process_date · created_at)原样保留,旧地址照旧有效;再加上表上存着的几列。
//   工单编号与物料平衡状态是另外查出来的,不可排。状态按库里的码排(与 payments 同)。
export const PROCESSING_SORT = {
    process_date: 'process_date', created_at: 'created_at', code: 'code',
    totalInput: 'total_input', totalOutput: 'total_output', loss: 'loss_qty', status: 'status',
} as const
export type ProcessingSortCol = keyof typeof PROCESSING_SORT
export const PROCESSING_SORTABLE = Object.keys(PROCESSING_SORT) as ProcessingSortCol[]
// ★ Q7:默认按加工日(新的在前),平局按建立时刻、再按 id —— 原来默认按建立时刻,而筛选按的是加工日。
const PROCESSING_SORT_DEFAULT: ListSort<ProcessingSortCol> = { key: 'process_date', dir: 'desc' }
const PROCESSING_TIEBREAK = [['created_at', 'desc'], ['id', 'asc']] as const

export interface ProcessingListParams {
    dateFrom: string // '' 表示不按 process_date 起始过滤
    dateTo: string // '' 表示不按 process_date 结束过滤
    sort: ListSort<ProcessingSortCol>
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
    return { dateFrom, dateTo, sort: parseListSort(sp, PROCESSING_SORTABLE, PROCESSING_SORT_DEFAULT) }
}

// supabase filter builder 的最小链式子集(避免引入其深泛型)。
interface ProcessingQueryChain {
    is(column: string, value: null): ProcessingQueryChain
    gte(column: string, value: string): ProcessingQueryChain
    lte(column: string, value: string): ProcessingQueryChain
}

// 套用 软删除过滤 / process_date 区间。不做分页(列表页另行 .range())。
// TABLE-FEATURES-1 Q9:排序挪到 applyProcessingSort —— 计数查询不必排序。
export function applyProcessingFilters<T>(query: T, params: ProcessingListParams): T {
    const { dateFrom, dateTo } = params
    let chain = query as unknown as ProcessingQueryChain
    chain = chain.is('deleted_at', null)
    if (dateFrom) chain = chain.gte('process_date', dateFrom)
    if (dateTo) chain = chain.lte('process_date', dateTo)
    return chain as unknown as T
}

// TABLE-FEATURES-1 Q9 · Q7:选中的列,再按建立时刻、id 平局(翻页取全要求唯一的次序)。
export function applyProcessingSort<T>(query: T, params: ProcessingListParams): T {
    return applyListSort(query, params.sort, PROCESSING_SORT, PROCESSING_TIEBREAK)
}
