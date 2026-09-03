// app/operation/wip/page.tsx
// PROC-WIRE-1B-ii(R3):在制品 —— 什么在等、多少、等哪一道工序。
//
// CONV-5:套 CONV-1 的两文件模板。state 恒为 'ok' —— 页顶那句 note 说明这一页
// 读的是一个投影而不是一张 WIP 表,空态下同样要看得见,所以它走 intro
// (画在状态分支之前),空集由 DataTable 自己的 empty 说。
//
// ★【没有 WIP 表,这一页读的是一个【投影】】★ 在制品那一行就是 output_batches
// 里那一行(PROC-WIRE-1A 立的:purpose_code = 'process_feed' 的产出批就是在制品)。
// 再建一张表会把同一批料数两遍,而两处迟早各说各话 —— R3 明写"不需要新对象"。
//
// 【为什么这一页在【加工】模块下,而不是在产出批次列表里】它回答的是产线的问题
// ("下一炉该跑什么"),不是库存的问题。视图的谓词也挂在 module.processing.view 上。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import WipTable, { type WipRow } from './WipTable'

export default async function WipPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前。
    const denied = await requireModule(MOD.processing)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const rows = mustRows(
        await supabase.from('processing_wip')
            .select('output_batch_id, batch_code, material_code, material_name, remaining_qty, unit, awaiting_operation_type_code, awaiting_operation_zh, awaiting_operation_en, safety_states_recorded')
            .order('batch_code'),
        'processing_wip') as {
            output_batch_id: string; batch_code: string
            material_code: string | null; material_name: string | null
            remaining_qty: number; unit: string
            awaiting_operation_type_code: string | null
            awaiting_operation_zh: string | null; awaiting_operation_en: string | null
            safety_states_recorded: number }[]

    const tableRows: WipRow[] = rows.map((r) => ({
        outputBatchId: r.output_batch_id,
        batchCode: r.batch_code,
        material: `${r.material_code ?? '—'}${r.material_name ? ` · ${r.material_name}` : ''}`,
        qty: `${r.remaining_qty} ${r.unit}`,
        // 工序名的语言在服务端选好;没排到工序时给 null,由表画"还没决定"
        awaitingLabel: r.awaiting_operation_type_code
            ? ((locale === 'zh' ? r.awaiting_operation_zh : r.awaiting_operation_en) ?? r.awaiting_operation_type_code)
            : null,
        safetyStatesRecorded: r.safety_states_recorded,
    }))

    return (
        <ListPage
            title={t('processing.wip.title')}
            intro={t('processing.wip.note')}
            state={{ kind: 'ok' }}
        >
            <WipTable rows={tableRows} empty={t('processing.wip.empty')} />
        </ListPage>
    )
}
