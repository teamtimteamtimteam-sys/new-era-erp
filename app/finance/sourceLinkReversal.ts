// app/finance/sourceLinkReversal.ts
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1c-1(Tim 的 Q15,2026-10-03)· 冲销分录的"来源"链接
// ════════════════════════════════════════════════════════════════════════════
// 【病】reverse_journal_entry_internal 建冲销分录时 source_type 照抄原分录,source_id 填的是【原分录】的 id
//   (不是原单据的 id —— AGENTS.md「source_id 在冲销件上指的是原分录」)。sourceLinks.ts 拿那个 id 当单据 id 去拼链接:
//   purchase 的冲销链到 /inbound/<原分录 id>/edit、allocation 的冲销链到 /operation/processing/<原分录 id> —— 两个都 404
//   (线上 2 张进货冲销、1 张分摊冲销)。
// 【治】先问:这个 source_id 是不是一张分录的 id?是 → 它是一张冲销,来源换成【那张原分录的】来源,再照常解析。
//   一跳就够:冲销不会再被冲销(guard_journal_entry_mutation 只许 posted → reversed 一次)。
// 【为什么单独一个文件、一个 import 都没有】scripts/check-trail-wording.mjs 用 Node 的 type-stripping 把它 import 进去
//   跑一格金句(sourceLinks.ts 自己 import 了 supabase 的类型与 '@/…' 别名,Node 认不得)。
export type SourceRef = { source_type: string | null; source_id: string | null }
export type JournalSource = { id: string; source_type: string | null; source_id: string | null }

/** 每一条来源 → 真正该链到的那一条来源(不是冲销的原样返回)。键是原来那一条的 `${type}:${id}` */
export function effectiveSources(refs: SourceRef[], journals: JournalSource[]): Map<string, SourceRef> {
    const byId = new Map(journals.map((j) => [j.id, j]))
    const out = new Map<string, SourceRef>()
    for (const r of refs) {
        const key = `${r.source_type}:${r.source_id}`
        const orig = r.source_id ? byId.get(r.source_id) : undefined
        out.set(key, orig && orig.source_type === r.source_type ? { source_type: orig.source_type, source_id: orig.source_id } : r)
    }
    return out
}
