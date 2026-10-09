// app/quality/samples/batchOptions.ts
// MES-6a-1:两张新建页(样品 · 争议)共用的批次清单与"这一批是谁"。读不到的那一侧 RLS 给零行 —— 所以另问一次码,屏幕说「受限」。
import type { createClient } from '@/lib/supabase/server'
import { mustRows, mustOne } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import type { BatchRef } from '../qualityTypes'
import type { BatchOption } from './BatchPicker'

type Supa = Awaited<ReturnType<typeof createClient>>

export async function loadBatchOptions(supabase: Supa) {
    const [canIn, canOut] = await Promise.all([can('module.inbound.view'), can('module.output.view')])
    const [inRes, outRes] = await Promise.all([
        canIn ? supabase.from('inbound_batches_masked').select('id, code').is('deleted_at', null).order('created_at', { ascending: false }).limit(300) : null,
        canOut ? supabase.from('output_batches').select('id, code').is('deleted_at', null).order('created_at', { ascending: false }).limit(300) : null,
    ])
    const inbound: BatchOption[] = inRes ? (mustRows(inRes, 'inbound_batches_masked') as { id: string; code: string }[]).map((b) => ({ value: `inbound:${b.id}`, label: b.code })) : []
    const output: BatchOption[] = outRes ? (mustRows(outRes, 'output_batches') as { id: string; code: string }[]).map((b) => ({ value: `output:${b.id}`, label: b.code })) : []
    return { inbound, output, canIn, canOut }
}

/** 这一批的编号;读不到(不存在、已删、或没有那一侧的查看码)→ null */
export async function loadBatchCode(supabase: Supa, ref: BatchRef): Promise<string | null> {
    // 进料批是遮蔽表(单价)—— 读它的 _masked 视图;这里只要编号
    const res = ref.kind === 'inbound'
        ? await supabase.from('inbound_batches_masked').select('code').eq('id', ref.id).is('deleted_at', null).maybeSingle()
        : await supabase.from('output_batches').select('code').eq('id', ref.id).is('deleted_at', null).maybeSingle()
    const row = mustOne(res, ref.kind === 'inbound' ? 'inbound_batches_masked' : 'output_batches') as { code: string | null } | null
    return row?.code ?? null
}
