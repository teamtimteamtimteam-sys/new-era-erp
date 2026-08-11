'use server'

// 金属含量(化验)行的服务端动作。进料/产出各两支:save = 按复合主键 upsert,delete = 硬删。
// 金属含量是【属性行,非审计腿】(cut 2 已定):允许硬删除,批次软删除覆盖历史。
// factory-free:四个动作各自显式写出(具体表名 + 具体列名),让生成的 DB 类型能精确套用。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { METAL_VALUES } from '@/app/metal-prices/options'

// 纯校验(不涉及 supabase 类型):金属 ∈ 7 集合,0 ≤ pct ≤ 100。
function metalInvalid(metal: string, contentPct: number): boolean {
    return (
        !METAL_VALUES.includes(metal) ||
        Number.isNaN(contentPct) ||
        contentPct < 0 ||
        contentPct > 100
    )
}

export async function saveInboundMetal(batchId: string, metal: string, contentPct: number) {
    const t = await getTranslations()
    if (metalInvalid(metal, contentPct)) return { error: t('metalContent.errInvalid') }

    const supabase = await createClient()

    // 父批次必须存在且未软删除
    const { data: parent } = await supabase
        .from('inbound_batches')
        .select('id')
        .eq('id', batchId)
        .is('deleted_at', null)
        .maybeSingle()
    if (!parent) return { error: t('metalContent.errBatchGone') }

    const {
        data: { user },
    } = await supabase.auth.getUser()

    // PROC-1:出处是【记录】的 —— 这条路径就是"人填的",而且覆盖一行化验来源的
    // 含量时必须把出处一并翻成 manual(留着旧的 source_assay_id 就是让化验单
    // 替一次手工改动背书)。
    const { error } = await supabase.from('inbound_batch_metals').upsert(
        {
            inbound_batch_id: batchId,
            metal,
            content_pct: contentPct,
            content_source: 'manual',
            source_assay_id: null,
            updated_by: user?.id ?? null,
        },
        { onConflict: 'inbound_batch_id,metal' }
    )
    if (error) return { error: t('metalContent.saveError', { message: error.message }) }

    revalidatePath(`/inbound/${batchId}/edit`)
    return {}
}

export async function deleteInboundMetal(batchId: string, metal: string) {
    const t = await getTranslations()
    if (!METAL_VALUES.includes(metal)) return { error: t('metalContent.errInvalid') }

    const supabase = await createClient()

    const { data: parent } = await supabase
        .from('inbound_batches')
        .select('id')
        .eq('id', batchId)
        .is('deleted_at', null)
        .maybeSingle()
    if (!parent) return { error: t('metalContent.errBatchGone') }

    const { error } = await supabase
        .from('inbound_batch_metals')
        .delete()
        .eq('inbound_batch_id', batchId)
        .eq('metal', metal)
    if (error) return { error: t('metalContent.deleteError', { message: error.message }) }

    revalidatePath(`/inbound/${batchId}/edit`)
    return {}
}

export async function saveOutputMetal(batchId: string, metal: string, contentPct: number) {
    const t = await getTranslations()
    if (metalInvalid(metal, contentPct)) return { error: t('metalContent.errInvalid') }

    const supabase = await createClient()

    const { data: parent } = await supabase
        .from('output_batches')
        .select('id')
        .eq('id', batchId)
        .is('deleted_at', null)
        .maybeSingle()
    if (!parent) return { error: t('metalContent.errBatchGone') }

    const {
        data: { user },
    } = await supabase.auth.getUser()

    // PROC-1:同上 —— 手工格子写的就是 manual,并抹掉可能残留的化验出处。
    const { error } = await supabase.from('output_batch_metals').upsert(
        {
            output_batch_id: batchId,
            metal,
            content_pct: contentPct,
            content_source: 'manual',
            source_assay_id: null,
            updated_by: user?.id ?? null,
        },
        { onConflict: 'output_batch_id,metal' }
    )
    if (error) return { error: t('metalContent.saveError', { message: error.message }) }

    revalidatePath(`/output/${batchId}/edit`)
    return {}
}

export async function deleteOutputMetal(batchId: string, metal: string) {
    const t = await getTranslations()
    if (!METAL_VALUES.includes(metal)) return { error: t('metalContent.errInvalid') }

    const supabase = await createClient()

    const { data: parent } = await supabase
        .from('output_batches')
        .select('id')
        .eq('id', batchId)
        .is('deleted_at', null)
        .maybeSingle()
    if (!parent) return { error: t('metalContent.errBatchGone') }

    const { error } = await supabase
        .from('output_batch_metals')
        .delete()
        .eq('output_batch_id', batchId)
        .eq('metal', metal)
    if (error) return { error: t('metalContent.deleteError', { message: error.message }) }

    revalidatePath(`/output/${batchId}/edit`)
    return {}
}
