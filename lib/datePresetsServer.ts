import 'server-only'
// lib/datePresetsServer.ts —— TABLE-FEATURES-2 Q5:服务端取「今天」(新加坡)与财年年末,算出四个快捷区间。算术在 lib/datePresets.ts。
// 财年年末从 fiscal_year_end_setting() 来(Tim 2026-10-26 Q5:任何登录用户都读得到的两个数);读不到就抛 —— 不猜一个 12 月 31 日。
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'
import { businessToday } from '@/lib/format'
import { datePresets, type DatePreset } from '@/lib/datePresets'

export async function readDatePresets(supabase: SupabaseClient<Database>): Promise<DatePreset[]> {
    const rows = mustRows(await supabase.rpc('fiscal_year_end_setting'), 'fiscal year end')
    const fy = rows[0]
    if (!fy || fy.fy_end_month == null || fy.fy_end_day == null) throw new Error('DATE_PRESETS_NO_FY_END|finance_settings has no row')
    return datePresets(businessToday(), { month: fy.fy_end_month, day: fy.fy_end_day })
}
