// lib/trail/changeLogFilters.ts
// GOLIVE-2 第 13 行:/settings/change-history 的筛选 → change_log_page / change_log_count 的参数 —— 页面与它的导出路由共用这一份,
//   所以 Q7 那句「页面上每一个筛选都生效」不靠两处各写一遍(只看关键事件不在这里:它由造句器判,导出在写文件时按它筛,Tim 2026-10-30 Q3)。
import { mustRows } from '@/lib/db-helpers'

export const CHANGE_LOG_WHO_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export type ChangeLogFilter = {
    from: string; to: string; type: string; tables?: string[]; recordIds?: string[]; who: string
}

export function changeLogFilterArgs(f: ChangeLogFilter & { entries?: number; before?: number }) {
    return {
        p_from: f.from || undefined,
        p_to: f.to || undefined,
        p_table: f.type || undefined,
        p_tables: f.tables,
        p_record_ids: f.recordIds,
        p_actor: CHANGE_LOG_WHO_UUID.test(f.who) ? f.who : undefined,
        p_no_session: f.who === 'system',
        p_removed_account: f.who === 'removed',
        ...(f.entries !== undefined ? { p_entries: f.entries } : {}),
        ...(f.before !== undefined ? { p_before: f.before } : {}),
    }
}

// ── 一块一块地读(页面与导出共用)───────────────────────────────────────────────────────────────────────────────────────
// GOLIVE-2 线上证明量到的:线上 authenticated 的 statement_timeout = 8 s,而免费档上一次读 501 次操作(7,602 行)撞上了它(57014)——
//   年体量种子上同一次调用 2.65 s,所以库里那支函数没错,错在"一次读完"这个假设。于是:
//   ① 一块 BLOCK_ENTRIES 次操作(p_before 键集往前接;一笔事务永远不被切成两块),与页面原来那一圈同一种保证(F19:每一次调用有上界);
//   ② 一块撞上语句超时 → 把这一块减半再读;
//   ③ 减到一次操作还超时(一笔几百行的批量授权)→ 那一次操作改走原来的 change_log_rows(p_by_entry、行 100 一页 —— F19 那条路,
//      交出的行与 change_log_page 逐行相同,fixture 305)。
export const BLOCK_ENTRIES = 20
type Rpc = (fn: string, args: Record<string, unknown>) => PromiseLike<{ data: unknown; error: { message: string; code?: string } | null }>
export type ChangeLogBatch<R> = { rows: R[]; entries: number; exhausted: boolean }

const isTimeout = (e: { message: string; code?: string } | null) => !!e && (e.code === '57014' || /statement timeout/i.test(e.message))

export async function readChangeLog<R extends { seq: number; txid: number }>(rpc: Rpc, f: ChangeLogFilter, target: number): Promise<ChangeLogBatch<R>> {
    const rows: R[] = []
    let before: number | undefined
    let read = 0
    let block = BLOCK_ENTRIES
    for (;;) {
        if (read >= target) return { rows, entries: read, exhausted: false }
        const want = Math.min(block, target - read)
        const r = await rpc('change_log_page', changeLogFilterArgs({ ...f, entries: want, before }))
        if (isTimeout(r.error) && want > 1) { block = Math.max(1, Math.floor(want / 2)); continue }
        if (isTimeout(r.error)) {
            // ③ 一次操作就超时:原来的读法,事务 1 笔、行 100 一页
            let rowBefore: number | undefined
            const one: R[] = []
            for (;;) {
                const p = await rpc('change_log_rows', { ...changeLogFilterArgs(f), p_by_entry: true, p_before: before, p_limit: 1, p_row_before: rowBefore, p_row_limit: 100 })
                const part = mustRows(p as { data: R[] | null; error: { message: string; code?: string } | null }, 'change_log_rows')
                one.push(...part)
                if (part.length < 100) break
                rowBefore = Math.min(...part.map((x) => x.seq))
            }
            if (one.length === 0) return { rows, entries: read, exhausted: true }
            rows.push(...one)
            read += 1
            before = Math.max(...one.map((x) => x.seq))
            block = Math.min(BLOCK_ENTRIES, 2)
            continue
        }
        if (r.error) throw new Error(`查询失败(change_log_page): ${r.error.code ?? ''} ${r.error.message}`.trim())
        const j = r.data as { rows: R[]; entries: number; next_before: number | null; exhausted: boolean }
        rows.push(...j.rows)
        read += j.entries
        block = Math.min(BLOCK_ENTRIES, block * 2)      // 读过了一段重的,块再长回去
        if (j.exhausted || j.next_before == null) return { rows, entries: read, exhausted: true }
        before = j.next_before
    }
}
