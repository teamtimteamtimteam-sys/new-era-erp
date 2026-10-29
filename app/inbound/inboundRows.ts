import 'server-only'

// TABLE-EXPORT-1(Tim 2026-10-22 Q2):进料台账的【一份】读取 —— 页面与导出路由共用。
// 页面取一页(.range),导出路由翻页取全(lib/export/serverRows.ts);两者走同一个 select、同一套筛选、
// 同一个「库里的行 → 表的行」映射,于是导出不可能比屏幕多一列或多一种口径。
// 排序在页面自己的排序列之后补一个 id —— 翻页取全要求一个【唯一】的次序(同一刻建的两行不再随机互换)。
//
// ★ 按 id 补读的那几张表(化验状态 · 定价申请 · 销毁证书 · 采购单号)在页面上只补一页 20 个 id;
//   导出时是全体,所以按 200 个 id 分批 —— 一个 .in() 里塞几万个 id 会把 URL 撑破(与 materialRows.ts 同一个理由)。

import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { openWarehouseRequestsByCode } from '@/lib/warehouseRequests'
import { can } from '@/lib/permissions'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import type { createClient } from '@/lib/supabase/server'
import { STAGE_OPTIONS, labelKeyForValue } from './options'
import { applyInboundFilters, type InboundListParams } from './inboundQuery'
import type { InboundTableRow } from './InboundTable'

type ServerSupabase = Awaited<ReturnType<typeof createClient>>

// FK 嵌入运行时是对象;TS 默认猜数组(无生成 DB 类型),用显式类型 + cast 锁住。
export type InboundRow = {
    id: string
    code: string
    quantity: number
    unit: string
    remaining_qty: number
    arrival_date: string | null
    stage: string
    status: string
    pricing_status: string
    created_at: string
    // RECV-SOURCE-1:来源三态(采购行 / 理由 / 未说明)—— 列表列要用
    purchase_order_id: string | null
    purchase_order_line_id: string | null
    source_reason_code: string | null
    // FIX-2b:内嵌换成两个 FK —— 名字在 TS 里从查名视图拼(见 INBOUND_LIST_SELECT 的注释)。
    material_id: string | null
    supplier_id: string | null
}

// ★★【FIX-2b:内嵌拿掉了 —— 它是同一条缺陷的第二半,而且更难看见】★★
//   `materials ( name )` / `suppliers ( legal_name )` 是 PostgREST 的内嵌:
//   它读的是【基表】,所以对 warehouse 与 operations 一律解析成 null,
//   下面 shape 的 `?? '—'` 把它渲染成一根破折号。
//   于是屏幕上是【一整列的破折号】—— 而破折号读起来是"这条记录没填",
//   不是"你看不到"。名字改在 TS 里从两张查名视图拼(本仓库既有做法:
//   「视图上不做 embed,分开查、在 TS 里拼」,见 /finance/expenses/new 的注释)。
const INBOUND_LIST_SELECT = `
        id, code, quantity, unit, remaining_qty, arrival_date, stage, status, pricing_status, created_at,
        purchase_order_id, purchase_order_line_id, source_reason_code,
        material_id, supplier_id
    `

// 匹配总数(同样套用过滤 + 搜索;只 select 'id' 不带嵌入 —— 过滤都打在本表列上,无需 join)
export function inboundCount(supabase: ServerSupabase, params: InboundListParams, searchOr: string | null) {
    return applyInboundFilters(
        supabase.from('inbound_batches').select('id', { count: 'exact', head: true }),
        params,
        searchOr
    )
}

export async function inboundPage(
    supabase: ServerSupabase, params: InboundListParams, searchOr: string | null, from: number, to: number,
) {
    const { data, error } = await applyInboundFilters(
        supabase.from('inbound_batches').select(INBOUND_LIST_SELECT),
        params,
        searchOr
    ).order('id', { ascending: true }).range(from, to)
    return { data: data as unknown as InboundRow[] | null, error }
}

/** 名字表:两张查名视图,谓词都含 module.inbound.view(见 page.tsx 的 FIX-2b 注释)。 */
export type InboundNames = { materialNameById: Map<string, string>; supplierNameById: Map<string, string> }

/**
 * 导出路由用:读两张查名视图拼名字表。页面不调它 —— 页面的下拉已经读过同两张视图,
 * 由页面自己把那份结果做成名字表(★ FIX-2b fu2:名字表取【全部】,货代只在下拉那一步筛掉)。
 */
export async function loadInboundNames(supabase: ServerSupabase): Promise<InboundNames> {
    const [matNameRes, supNameRes] = await Promise.all([
        supabase.from('material_lookup').select('id, name').is('deleted_at', null),
        supabase.from('supplier_lookup').select('id, legal_name').is('deleted_at', null),
    ])
    return {
        materialNameById: new Map((mustRows(matNameRes) as unknown as
            { id: string; name: string }[]).map((m) => [m.id, m.name])),
        supplierNameById: new Map((mustRows(supNameRes) as unknown as
            { id: string; legal_name: string }[]).map((s) => [s.id, s.legal_name])),
    }
}

/** 按 200 个 id 一批跑同一条 .in() 读取,结果拼起来;每一批都过 mustRows(失败不是空集)。 */
async function inChunks<R>(ids: string[], read: (chunk: string[]) => PromiseLike<{ data: R[] | null; error: { message: string } | null }>, what: string): Promise<R[]> {
    const out: R[] = []
    for (let i = 0; i < ids.length; i += 200) {
        out.push(...(mustRows(await read(ids.slice(i, i + 200)), what) as R[]))
    }
    return out
}

export async function shapeInboundRows(
    supabase: ServerSupabase, batches: InboundRow[], names: InboundNames,
): Promise<InboundTableRow[]> {
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'
    const ids = batches.map((b) => b.id)

    // 本页各批次是否有"已记录未应用"的化验(cut 5b);只查当前这些 id —— 同
    // 采购单详情页取已抵扣额的做法
    // TABLE-EXPORT-1:此前是 `{ data: assayStatusRows }` 不看 error —— 读不出来会把每一行画成"没有未应用化验"。
    //   搬过来时改走 mustRows(失败不是空集)。
    const assayStatusRows = ids.length
        ? await inChunks(ids, (chunk) => supabase
              .from('batch_assay_status')
              .select('inbound_batch_id, has_unapplied_assay')
              .in('inbound_batch_id', chunk), 'batch_assay_status')
        : []
    // ── ROLE-1 Batch 4b:哪几张收货挂着在等 CFO 的定价申请 ─────────────────────────
    //   申请表的读策略要 inbound.view + 采购码;不持采购码的人不去读(读了是 0 行,而 0 行
    //   不许画成"没有申请")—— 那时这一列不画徽标,注销按钮照常,由库按名拒(RECEIPT_PRICE_REQUEST_OPEN)。
    const openPriceRequestByBatch = new Map<string, string>()
    if (ids.length > 0 && await can('data.view_purchase_prices')) {
        const reqRows = await inChunks(ids, (chunk) => supabase
            .from('receipt_price_requests')
            .select('inbound_batch_id, label')
            .eq('status', 'submitted')
            .in('inbound_batch_id', chunk), 'receipt_price_requests')
        for (const r of reqRows as { inbound_batch_id: string; label: string }[]) {
            openPriceRequestByBatch.set(r.inbound_batch_id, r.label)
        }
    }
    // ── APR-7:注销要不要经 CFO(grilling Q1 —— 与库里 batch_write_off_needs_request 同一条判据:
    //   还有料,或挂着一张【已签发】的销毁证书),以及哪一张在等的申请碰到了这一批。
    //   这一格只喂注销钮,所以问的是签发 / 注销那一侧的码 action.issue_cod(持注销码的 admin · warehouse 都持它)——
    //   ★ COD-READERS(Tim 2026-10-29):证书表的读从此是 data.view_cod,而这一格【刻意】留在 action.issue_cod:
    //   只读的读者(cfo · cco · cto · finance · gm)不持注销的码,替他们多读一遍证书什么都不改变。
    //   不持它的人这一格按"没有证书"画,库照样按名拒。
    const issuedCodBatches = new Set<string>()
    if (ids.length > 0 && await can('action.issue_cod')) {
        const codRows = await inChunks(ids, (chunk) => supabase
            .from('certificates_of_destruction')
            .select('inbound_batch_id')
            .eq('status', 'issued')
            .in('inbound_batch_id', chunk), 'certificates_of_destruction')
        for (const r of codRows as { inbound_batch_id: string }[]) issuedCodBatches.add(r.inbound_batch_id)
    }
    const openWarehouseRequest = await can('module.inventory.view')
        ? await openWarehouseRequestsByCode(supabase)
        : new Map<string, string>()
    const unappliedByBatch = new Set(
        (assayStatusRows as { inbound_batch_id: string | null; has_unapplied_assay: boolean | null }[])
            .filter((r) => r.has_unapplied_assay)
            .map((r) => r.inbound_batch_id ?? '')
    )

    // ── RECV-SOURCE-1:来源列的三态 ─────────────────────────────────────────────
    // 【未说明永远不是空白格】8 张早于本刀的无单收货按 R4 不回填,在这里必须
    // 读作【未说明】(琥珀),与"对着采购行"(蓝)与"有理由"(灰)看得出区别。
    // 理由标签从字典读、按语言选一个(GST-FIX-3);采购单号躲在
    // module.purchasing.view 后面(OPS-14),没有权限时给一句通用的"对着采购单",
    // 不让 RLS 丢行把"有单"渲染成别的东西。
    const canViewPurchasing = await can('module.purchasing.view')
    const poIds = [...new Set(batches
        .filter((b) => b.purchase_order_line_id && b.purchase_order_id)
        .map((b) => b.purchase_order_id as string))]
    const poCodeById = new Map<string, string>()
    if (canViewPurchasing && poIds.length) {
        const poRows = await inChunks(poIds, (chunk) =>
            supabase.from('purchase_orders_masked').select('id, code').in('id', chunk), 'purchase_orders_masked')
        for (const r of poRows) {
            if (r.id && r.code) poCodeById.set(r.id, r.code)
        }
    }
    const reasonRes = await supabase
        .from('inbound_source_reasons').select('code, name_en, name_zh')
    const reasonLabelByCode = new Map(
        mustRows(reasonRes, 'inbound_source_reasons')
            .map((r) => [r.code, locale === 'zh' ? r.name_zh : r.name_en])
    )

    // stage 存储值反查成本地化文案;未知值原样显示
    const stageLabel = (value: string) => {
        const key = labelKeyForValue(STAGE_OPTIONS, value)
        return key ? t(key) : value
    }

    // ── CONV-1:把这一页要显示的东西【在服务端压平成纯数据】───────────────────
    //   来源那一列要三样服务端才知道的东西(采购单号 / 理由字典的本地化名字 /
    //   两样都没有 = 未说明),阶段标签要 options 的反查。都在这里算完,
    //   客户端只拿到「这一格该显示什么」。理由见 InboundTable.tsx 的抬头。
    return batches.map((b) => {
        const poCode = b.purchase_order_line_id
            ? (poCodeById.get(b.purchase_order_id ?? '') ?? t('inbound.source.fromPo'))
            : null
        return {
            id: b.id,
            code: b.code,
            // FIX-2b:名字来自两张查名视图,不再来自内嵌。
            // 拼不上仍然是 '—',但那时它的含义回到了【真的没有这一项】:
            // 权限那一半已经在视图的谓词里答过了。
            materialName: (b.material_id ? names.materialNameById.get(b.material_id) : null) ?? '—',
            supplierName: (b.supplier_id ? names.supplierNameById.get(b.supplier_id) : null) ?? '—',
            sourceKind: b.purchase_order_line_id ? 'po' : b.source_reason_code ? 'reason' : 'unexplained',
            sourceLabel: b.purchase_order_line_id
                ? poCode
                : b.source_reason_code
                  ? (reasonLabelByCode.get(b.source_reason_code) ?? b.source_reason_code)
                  : null,
            quantity: b.quantity,
            remaining: b.remaining_qty,
            unit: b.unit,
            arrivalDate: b.arrival_date ? formatDate(b.arrival_date, dateLocale) : null,
            arrivalDateRaw: b.arrival_date,
            stageLabel: stageLabel(b.stage),
            status: b.status,
            pricingStatus: b.pricing_status,
            hasUnappliedAssay: unappliedByBatch.has(b.id),
            openPriceRequest: openPriceRequestByBatch.get(b.id) ?? null,
            needsWriteOffRequest: b.remaining_qty > 0 || issuedCodBatches.has(b.id),
            openWarehouseRequest: openWarehouseRequest.get(b.code) ?? null,
            createdLabel: formatAuditStamp(b.created_at),
            createdAt: b.created_at,
        }
    })
}
