'use server'

// MES-8b-2(2026-10-17,MES-0 §5.1 V28 · MES-8 Step 0 Q20,Tim):给 / 清 V28 —— 大屏自己刷新的间隔与画哪几块牌子。
//   判据全在 set_floor_board_settings 里(两样一起给、牌子只能是车间支、不重复、间隔为正);这里一句都不重写。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { refuseFromCoded, type ActionOutcome } from '@/lib/action-refusal'
import { localizeFloorBoardError } from './displayErrorCodes'

export async function setFloorBoardSettings(refreshSeconds: number | null, tiles: string[] | null): Promise<ActionOutcome> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('set_floor_board_settings', {
        p_refresh_seconds: refreshSeconds as number, p_tiles: tiles as string[],
    })
    if (error) return await refuseFromCoded(error.message, localizeFloorBoardError)
    revalidatePath('/display')
    revalidatePath('/settings/pending-values')
    return { success: true }
}
