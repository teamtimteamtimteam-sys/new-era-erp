// app/components/audit/auditTrailQuery.ts
// AUDIT-1:取一个批次的审计轨迹。**读外层视图 batch_audit_trail**,
// 【绝不】读 batch_audit_trail_all —— 那一张不授权给任何人,判据在外层
// (AUD-1 的拆法,理由写在两张视图的抬头)。
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import type { AuditTrailRow } from './auditTrailTypes'

export async function loadBatchAuditTrail(
    batchKind: 'inbound' | 'output',
    batchId: string
): Promise<AuditTrailRow[]> {
    const supabase = await createClient()
    // 【失败必须失败】(lib/db-helpers 抬头)。一条读不出来的轨迹如果退化成 []
    // ,屏幕会说"这个批次什么都没发生过" —— 本刀从头到尾要消灭的就是这句话。
    return mustRows(
        await supabase
            .from('batch_audit_trail')
            .select('*')
            .eq('batch_kind', batchKind)
            .eq('batch_id', batchId)
            .order('occurred_at', { ascending: true }),
        'batch_audit_trail'
    ) as AuditTrailRow[]
}
