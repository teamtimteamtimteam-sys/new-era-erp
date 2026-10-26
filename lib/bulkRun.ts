// lib/bulkRun.ts —— TABLE-FEATURES-3(Tim 2026-10-25 Q2):批量动作的跑法。纯算术,不碰库,浏览器与本地证明(scripts/check-bulk-run.mjs)用同一份。
//
// ★ 一次一项、走的就是单击那一扇门:每一项各调一次那张卡片上的单项动作(decideJournalRequest 之类),
//   于是四眼、CFO 档位、状态守卫、拒绝,全部【按项】由库判 —— 这里不预判谁能批什么。
//   一项被拒不停下:拒绝记在那一项上,接着跑下一项。结果名单逐项说「做成了」或「被拒了 + 它自己的理由」。
// ★ 一次动作抛了(网络断了、服务端崩了)也是那一项的拒绝,不是整批的失败 —— 理由用调用方给的那句人话,
//   原文进 detail(与 showActionMessage 同一个分工)。
export type BulkItem = { id: string; label: string }
export type BulkOutcome = { id: string; label: string; done: boolean; reason?: string; detail?: string }
type ActResult = { error?: string; detail?: string } | void | undefined

export async function runOneAtATime(
    items: readonly BulkItem[],
    act: (item: BulkItem) => Promise<ActResult>,
    { thrownReason, onProgress }: { thrownReason: string; onProgress?: (doneCount: number, total: number) => void },
): Promise<BulkOutcome[]> {
    const out: BulkOutcome[] = []
    for (const item of items) {
        onProgress?.(out.length, items.length)
        try {
            const r = await act(item)
            if (r && r.error) out.push({ id: item.id, label: item.label, done: false, reason: r.error, detail: r.detail })
            else out.push({ id: item.id, label: item.label, done: true })
        } catch (e) {
            out.push({ id: item.id, label: item.label, done: false, reason: thrownReason, detail: String((e as Error)?.message ?? e) })
        }
    }
    onProgress?.(out.length, items.length)
    return out
}

/** 选中的那几项,按屏幕上的先后(而不是勾选的先后)—— 结果名单与屏幕读起来是同一个顺序。 */
export function selectedInScreenOrder(onScreen: readonly BulkItem[], selected: ReadonlySet<string>): BulkItem[] {
    return onScreen.filter((i) => selected.has(i.id))
}

/** 全选只勾【屏幕上的】那几行(Q2):已全选 → 全部取消;否则 → 勾上屏幕上的每一行。屏幕外的选择不保留。 */
export function toggleAllOnScreen(onScreen: readonly BulkItem[], selected: ReadonlySet<string>): Set<string> {
    const all = onScreen.length > 0 && onScreen.every((i) => selected.has(i.id))
    return all ? new Set() : new Set(onScreen.map((i) => i.id))
}
