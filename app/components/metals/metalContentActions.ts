'use server'

// 金属含量(化验)行的服务端动作。进料/产出各两支:save = 按复合主键 upsert,delete = 硬删。
// 金属含量是【属性行,非审计腿】(cut 2 已定):允许硬删除,批次软删除覆盖历史。
// factory-free:四个动作各自显式写出(具体表名 + 具体列名),让生成的 DB 类型能精确套用。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { loadSubstances, loadSubstanceLabels } from '@/app/tools/pricing/metal-prices/substanceQuery'

// 纯校验:物质 ∈ 字典,0 ≤ pct ≤ 100。
// PROC-4:合法集合【由调用方现读字典传进来】,不再是一份写死的七元素清单 ——
// 那份清单曾经是这份名单的第五个副本。外键仍然是权威,这里只把话说成人话。
function metalInvalid(allowed: Set<string>, metal: string, contentPct: number): boolean {
    return (
        !allowed.has(metal) ||
        Number.isNaN(contentPct) ||
        contentPct < 0 ||
        contentPct > 100
    )
}

export async function saveInboundMetal(batchId: string, metal: string, contentPct: number) {
    const t = await getTranslations()
    const supabase = await createClient()
    const allowed = new Set((await loadSubstances(supabase)).map((r) => r.code))
    if (metalInvalid(allowed, metal, contentPct)) return { error: t('metalContent.errInvalid') }

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
    const supabase = await createClient()
    // 【删除这一侧也现读字典】—— 一种已经【停用】的物质,它的历史行仍然要删得掉。
    // loadSubstances 只给在用的,所以这里读【全部】:D5 的两个动词,停用管的是
    // "不能新选",不是"既有的行从此动不了"。
    const known = new Set((await loadSubstanceLabels(supabase)).map((r) => r.code))
    if (!known.has(metal)) return { error: t('metalContent.errInvalid') }

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
    const supabase = await createClient()
    const allowed = new Set((await loadSubstances(supabase)).map((r) => r.code))
    if (metalInvalid(allowed, metal, contentPct)) return { error: t('metalContent.errInvalid') }

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
    const supabase = await createClient()
    // 【删除这一侧也现读字典】—— 一种已经【停用】的物质,它的历史行仍然要删得掉。
    // loadSubstances 只给在用的,所以这里读【全部】:D5 的两个动词,停用管的是
    // "不能新选",不是"既有的行从此动不了"。
    const known = new Set((await loadSubstanceLabels(supabase)).map((r) => r.code))
    if (!known.has(metal)) return { error: t('metalContent.errInvalid') }

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
