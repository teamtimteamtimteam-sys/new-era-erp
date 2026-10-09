// app/components/quality/sampleOptions.ts
// MES-6a-1:化验表单的样品选单 —— 这一批的样品(sample_rows 的门:质量查看码或这一批自己的查看码,化验页的读者都过得去)。
import type { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { sampleKindKey, sampleStateKey } from '@/app/quality/qualityTypes'
import type { SampleOption } from './SamplePickerField'

type Supa = Awaited<ReturnType<typeof createClient>>

export async function loadBatchSampleOptions(supabase: Supa, kind: 'inbound' | 'output', batchId: string): Promise<SampleOption[]> {
    const t = await getTranslations()
    const rows = mustRows(
        await supabase.from('sample_rows').select('id, code, kind, state')
            .eq(kind === 'inbound' ? 'inbound_batch_id' : 'output_batch_id', batchId).order('created_at', { ascending: false }),
        'sample_rows') as { id: string; code: string; kind: string; state: string }[]
    return rows.map((r) => ({ id: r.id, label: `${r.code} · ${t(sampleKindKey(r.kind))} · ${t(sampleStateKey(r.state))}` }))
}
