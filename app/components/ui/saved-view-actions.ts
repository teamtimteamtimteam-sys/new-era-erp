'use server'

// TABLE-FEATURES-3(Tim 2026-10-25 Q3 · 2026-10-26 Q1–Q3):保存的视图的三扇门 —— 存(同名即覆盖)、删、设 / 取消默认。
// 写走 RLS(saved_views 只让本人碰自己的行),于是一次碰不到行的改 / 删【不报错、只是零行】(AGENTS.md「被 RLS 挡下的
// UPDATE 不是错误」)—— 每一句都带 .select('id'),零行不许报成功。
// 查询串在浏览器那头已经按 lib/savedViews.ts encodeViewQuery 去掉了翻页与一次性参数;这里只管长度与名字。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { refuseFromDriver, type ActionOutcome } from '@/lib/action-refusal'

const NAME_MAX = 60
const QUERY_MAX = 2000
const LIST_KEY = /^\/[a-z0-9/_-]*$/

async function notFound(): Promise<ActionOutcome> {
    const t = await getTranslations()
    return { error: t('savedViews.notFound') }
}

export async function saveView(listKey: string, name: string, query: string): Promise<ActionOutcome> {
    const t = await getTranslations()
    const n = name.trim()
    if (n === '') return { error: t('savedViews.nameRequired'), field: 'name' }
    if (n.length > NAME_MAX) return { error: t('savedViews.nameTooLong', { max: NAME_MAX }), field: 'name' }
    if (!LIST_KEY.test(listKey) || query.length > QUERY_MAX) return { error: t('savedViews.notSaved') }
    const supabase = await createClient()
    // 同一个人、同一张列表、同一个名字 → 覆盖那一个的查询串(默认与否不动)
    const { data, error } = await supabase.from('saved_views')
        .upsert({ list_key: listKey, name: n, query }, { onConflict: 'user_id,list_key,name' })
        .select('id')
    if (error) return refuseFromDriver(error.message)
    if (!data || data.length === 0) return { error: t('savedViews.notSaved') }
    revalidatePath(listKey)
    return { success: true }
}

export async function deleteView(listKey: string, id: string): Promise<ActionOutcome> {
    const supabase = await createClient()
    const { data, error } = await supabase.from('saved_views').delete().eq('id', id).select('id')
    if (error) return refuseFromDriver(error.message)
    if (!data || data.length === 0) return notFound()
    revalidatePath(listKey)
    return { success: true }
}

/** id = null → 这张列表不再有默认。先撤掉旧的、再立新的(部分唯一索引:每人每张列表至多一个)。 */
export async function setDefaultView(listKey: string, id: string | null): Promise<ActionOutcome> {
    const supabase = await createClient()
    const cleared = await supabase.from('saved_views').update({ is_default: false })
        .eq('list_key', listKey).eq('is_default', true).select('id')
    if (cleared.error) return refuseFromDriver(cleared.error.message)
    if (id !== null) {
        const { data, error } = await supabase.from('saved_views').update({ is_default: true })
            .eq('id', id).eq('list_key', listKey).select('id')
        if (error) return refuseFromDriver(error.message)
        if (!data || data.length === 0) return notFound()
    }
    revalidatePath(listKey)
    return { success: true }
}
