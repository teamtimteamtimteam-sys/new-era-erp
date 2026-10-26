import 'server-only'
// lib/savedViewsServer.ts —— TABLE-FEATURES-3(Tim 2026-10-25 Q3 · 2026-10-26 Q1–Q3):一张列表页读出本人在这张列表上的视图,
// 并在【地址里什么都没有】时套用本人的默认视图(Q3)—— 一个带着自己参数的链接(提醒、留痕、别处)从不被顶掉。
// 在页面里最先调用(任何别的查询之前):套用默认视图是一次跳转,跳之前的查询都白做。
// 读走 RLS(saved_views 只给本人自己的行),读失败就抛 —— 一张读不到的视图表不是"没有视图"(mustRows)。
import { redirect } from 'next/navigation'
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'
import { viewHref, type SavedView, type ViewDates } from '@/lib/savedViews'

export async function loadSavedViews(
    supabase: SupabaseClient<Database>,
    { listKey, sp, dates }: { listKey: string; sp: Record<string, string | string[] | undefined>; dates?: ViewDates },
): Promise<SavedView[]> {
    const views = mustRows(
        await supabase.from('saved_views').select('id, name, query, is_default')
            .eq('list_key', listKey).order('name', { ascending: true }),
        'saved views',
    )
    const addressIsEmpty = Object.values(sp).every((v) => v === undefined)
    const dflt = views.find((v) => v.is_default)
    if (addressIsEmpty && dflt) redirect(viewHref(listKey, dflt.query, dates))
    return views
}
