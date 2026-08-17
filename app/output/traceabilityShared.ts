// app/output/traceabilityShared.ts
// AUD-2:可追溯报告的取数与【单元格文案】——【屏幕与 PDF 共用这一份】。
//
// 【为什么单元格文案也要共用】这一族最要紧的规矩是"出处跟着数字走":
// NULL 的回收率印它的具名原因、'unknown' 印成 unknown。若屏幕一份、PDF 一份,
// 两份迟早各说各话 —— 而它们要说的正是同一个数是不是可信。
// 这就是 AGENTS.md 那条"预览过账的屏幕要问数据库"的同一形状,只是这次两个消费者
// 都在应用侧:一份实现,两个调用者。
//
// 【本文件不做任何推导】数字全部来自 db 的 traceability_report_data(AUD-1):
// 血缘链绝不第二次递归,回收率的 recovery_blocked_by / input_source /
// output_source 逐列原样带走。
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'

export type ChainRow = {
    depth: number
    via_run_id: string
    via_run_code: string
    parent_kind: 'inbound' | 'output'
    parent_batch_id: string
    parent_code: string | null
    quantity_consumed: number
    supplier_name: string | null
    supplier_code: string | null
    arrival_date: string | null
    material_code: string | null
}

export type RecoveryRow = {
    run_id: string
    run_code: string
    process_date: string | null
    metal: string
    input_metal_kg: number | null
    output_metal_kg: number | null
    input_measured: boolean
    output_measured: boolean
    recovery_pct: number | null
    recovery_blocked_by: string | null
    conservation_warning: boolean
    run_recovery_computable: boolean
    input_source: string | null
    output_source: string | null
}

export type TraceabilityReport = {
    output_batch: {
        id: string; code: string
        material_code: string | null; material_name: string | null
        quantity: number; remaining_qty: number; unit: string | null
        output_date: string | null
    }
    chain: ChainRow[]
    chain_depth: number | null
    runs: { run_id: string; run_code: string }[]
    recovery: RecoveryRow[]
    chain_row_count: number
    recovery_row_count: number
}

type T = (key: string, params?: Record<string, string | number>) => string

/** 取一份报告。服务端的具名拒绝【原样返回】,不翻成空对象 ——
 *  NOTHING_TO_REPORT 是一个答案,不是一次失败。 */
export async function fetchTraceability(
    supabase: SupabaseClient<Database>,
    outputBatchId: string
): Promise<TraceabilityReport | { error: string }> {
    const { data, error } = await supabase.rpc('traceability_report_data', {
        p_output_batch_id: outputBatchId,
    })
    if (error) return { error: error.message }
    return data as unknown as TraceabilityReport
}

/** 出处:'assay' / 'manual' / 'mixed' / 'unknown' / 没有那一侧。
 *  【unknown 就印 unknown,绝不抹平成 assay】—— PROC-1 之前录的行出处没人记过,
 *  而"没人记过"与"实验室说的"是两件事,客户审计问的正是这个区别。 */
export function sourceText(v: string | null | undefined, t: T): string {
    if (!v) return '—'
    // 四个取值都是字面量键(不是拼前缀),静态检查因此盖得住它们
    if (v === 'assay') return t('traceability.source.assay')
    if (v === 'manual') return t('traceability.source.manual')
    if (v === 'mixed') return t('traceability.source.mixed')
    if (v === 'unknown') return t('traceability.source.unknown')
    return v // 认不出的取值原样显示,而不是猜一个
}

/** 回收率那一格。
 *  【算不出就印它的具名原因,绝不印 0、绝不留空】0 是一个断言("什么都没回收出来"),
 *  空白读起来像"这一栏没填" —— 而真相是"这一侧从来没测过"。 */
export function recoveryText(r: RecoveryRow, t: T): string {
    if (r.recovery_pct !== null && r.recovery_pct !== undefined) {
        return `${r.recovery_pct}%`
    }
    if (r.recovery_blocked_by) {
        return t('traceability.blocked.' + r.recovery_blocked_by)
    }
    // 视图只产出那三种原因;真出了第四种,说"算不出"而不是编一个数
    return t('traceability.blocked.unspecified')
}

/** kg 那一格:没测过就说没测过,不写 0。 */
export function kgText(v: number | null | undefined, t: T): string {
    return v === null || v === undefined ? t('traceability.notMeasured') : String(v)
}

// ── PDF 用的 string[][] ────────────────────────────────────────────────────
// 屏幕用上面那几个 *Text 直接渲染;这里只是把同样的文案摆成表格行。

export function chainRows(rep: TraceabilityReport, t: T): string[][] {
    return rep.chain.map((c) => [
        String(c.depth),
        c.via_run_code,
        `${c.parent_kind === 'inbound' ? t('traceability.kindInbound') : t('traceability.kindOutput')} ${c.parent_code ?? '—'}`,
        String(c.quantity_consumed),
        c.supplier_name ? `${c.supplier_code ?? ''} ${c.supplier_name}`.trim() : '—',
        c.arrival_date ?? '—',
    ])
}

export function recoveryRows(rep: TraceabilityReport, t: T): string[][] {
    return rep.recovery.map((r) => [
        r.run_code,
        t('metals.' + r.metal),
        kgText(r.input_metal_kg, t),
        kgText(r.output_metal_kg, t),
        recoveryText(r, t) + (r.conservation_warning ? ` ${t('traceability.conservationFlag')}` : ''),
        sourceText(r.input_source, t),
        sourceText(r.output_source, t),
    ])
}
