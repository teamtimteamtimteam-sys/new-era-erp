import 'server-only'

// TABLE-EXPORT-1(Tim 2026-10-22 Q2):产出批次列表的【一份】读取 —— 页面与导出路由共用。
// 页面取一页(.range),导出路由翻页取全(lib/export/serverRows.ts);两者走同一个 select、同一套筛选、
// 同一个「库里的行 → 表的行」映射,于是导出不可能比屏幕多一列或多一种口径。
// 排序在页面自己的排序列之后补一个 id —— 翻页取全要求一个【唯一】的次序(同一刻建的两行不再随机互换)。

import { getTranslations, getLocale } from '@/lib/i18n/server'
import { openWarehouseRequestsByCode } from '@/lib/warehouseRequests'
import { can } from '@/lib/permissions'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import type { createClient } from '@/lib/supabase/server'
import { STATE_OPTIONS, labelKeyForValue } from '../inbound/options'
import { applyOutputFilters, type OutputListParams } from './outputQuery'
import type { OutputTableRow } from './OutputTable'

type ServerSupabase = Awaited<ReturnType<typeof createClient>>

// FK 嵌入运行时是对象;TS 默认猜数组(无生成 DB 类型),用显式类型 + cast 锁住。
// customers 可空:库存中的批次还没指派客户。
export type OutputRow = {
    id: string
    code: string
    quantity: number
    unit: string
    remaining_qty: number
    output_date: string | null
    state: string
    status: string
    created_at: string
    materials: { name: string } | null
    customers: { legal_name: string } | null
    // PROC-WIRE-1A:【另一条轴】—— 这批是干什么用的。是否可售【由字典那一列回答】,
    // 不由把码写死在这里回答,否则多一种不可售用途就要改代码。
    output_batch_purposes: { name_en: string; name_zh: string; is_saleable_stock: boolean } | null
}

const OUTPUT_LIST_SELECT = `
        id, code, quantity, unit, remaining_qty, output_date, state, status, created_at,
        materials ( name ),
        customers ( legal_name ),
        output_batch_purposes ( name_en, name_zh, is_saleable_stock )
    `

// 匹配总数(同样套用过滤 + 搜索;只 select 'id' 不带嵌入 —— 过滤都打在本表列上,无需 join)
export function outputCount(supabase: ServerSupabase, params: OutputListParams, searchOr: string | null) {
    return applyOutputFilters(
        supabase.from('output_batches').select('id', { count: 'exact', head: true }),
        params,
        searchOr
    )
}

// 带嵌入的 select(materials/customers 名字用于展示)+ 过滤 + 排序 + id 兜底 + .range
export async function outputPage(
    supabase: ServerSupabase, params: OutputListParams, searchOr: string | null, from: number, to: number,
) {
    const { data, error } = await applyOutputFilters(
        supabase.from('output_batches').select(OUTPUT_LIST_SELECT),
        params,
        searchOr
    ).order('id', { ascending: true }).range(from, to)
    return { data: data as unknown as OutputRow[] | null, error }
}

export async function shapeOutputRows(supabase: ServerSupabase, batches: OutputRow[]): Promise<OutputTableRow[]> {
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    // state 存储值反查成本地化文案;未知值原样显示
    const stateLabel = (value: string) => {
        const key = labelKeyForValue(STATE_OPTIONS, value)
        return key ? t(key) : value
    }

    // APR-7:哪一张在等的仓库申请碰到了这一批(注销它自己的,或回滚它那张加工单的)
    const openWarehouseRequest = await can('module.inventory.view')
        ? await openWarehouseRequestsByCode(supabase)
        : new Map<string, string>()

    return batches.map((b) => ({
        id: b.id,
        code: b.code,
        materialName: b.materials?.name ?? '—',
        customerName: b.customers?.legal_name ?? '—',
        quantity: `${b.quantity} ${b.unit}`,
        remaining: `${b.remaining_qty} ${b.unit}`,
        // TABLE-EXPORT-1:导出用的原始值(Excel 里是一个数,不是「12 kg」这串字)
        quantityQty: b.quantity,
        remainingQty: b.remaining_qty,
        // TABLE-EXPORT-1:屏幕上数后面跟着的那个单位(「12 kg」),导出时一起写
        unit: b.unit,
        // APR-7(grilling Q1):还有料 → 注销是一张给 CFO 的申请;空批一步删
        needsWriteOffRequest: b.remaining_qty > 0,
        openWarehouseRequest: openWarehouseRequest.get(b.code) ?? null,
        outputDate: formatDate(b.output_date, dateLocale) ?? '—',
        outputDateRaw: b.output_date,
        stateLabel: stateLabel(b.state),
        // PROC-WIRE-1A:用途角标的语言在服务端选好;可售的批次没有这个角标
        purposeTag:
            b.output_batch_purposes && !b.output_batch_purposes.is_saleable_stock
                ? (locale === 'zh' ? b.output_batch_purposes.name_zh : b.output_batch_purposes.name_en)
                : null,
        status: b.status,
        createdLabel: formatAuditStamp(b.created_at),
        createdAt: b.created_at,
    }))
}
