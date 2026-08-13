'use server'

// NTF-1:标记已读。【这张表与 notifications 相反,允许客户端直写】——
// 它记的不是"发生了什么"(那必须伪造不出来),而是"我看过了",而那句话
// 本来就只有读者自己说得出。RLS 把它限定在 user_id = auth.uid()。

import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { revalidatePath } from 'next/cache'
import { mustRows } from '@/lib/db-helpers'

export type MarkReadState = { error?: string }

export async function markRead(id: string): Promise<MarkReadState> {
    const t = await getTranslations()
    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()
    if (!user) return { error: t('notifications.errNotSignedIn') }

    // upsert:重复标记不该报错 —— 两次点击是同一句话说了两遍。
    const { error } = await supabase
        .from('notification_reads')
        .upsert({ notification_id: id, user_id: user.id }, { onConflict: 'notification_id,user_id' })
    if (error) return { error: t('notifications.errMarkRead', { message: error.message }) }

    revalidatePath('/notifications')
    revalidatePath('/', 'layout')   // 铃铛在 TopNav 上,它住在 layout 里
    return {}
}

export async function markAllRead(): Promise<MarkReadState> {
    const t = await getTranslations()
    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()
    if (!user) return { error: t('notifications.errNotSignedIn') }

    // 【只标记"我读得到的"】—— RLS 已经把看不见的行挡在外面,所以这里取到的
    // 就是这个读者的收件箱。用 mustRows:一次失败的查询【不是空集】,
    // 否则"全部已读"会在读不到任何东西时静悄悄地什么也不做并显示成功。
    const res = await supabase.from('notifications').select('id')
    const rows = mustRows(res, 'notifications')
    if (rows.length === 0) return {}

    const { error } = await supabase
        .from('notification_reads')
        .upsert(
            rows.map((r) => ({ notification_id: r.id, user_id: user.id })),
            { onConflict: 'notification_id,user_id' }
        )
    if (error) return { error: t('notifications.errMarkRead', { message: error.message }) }

    revalidatePath('/notifications')
    revalidatePath('/', 'layout')
    return {}
}
