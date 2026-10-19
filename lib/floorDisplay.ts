// lib/floorDisplay.ts
// MES-8b-2(2026-10-17,MES-0 Q83 · MES-8 Step 0 Q19,Tim):【这个会话是不是一块车间大屏】—— 服务端判,一次请求只判一次。
//
// 判据只有一份,住在数据库里:session_is_floor_display_only()(角色恰好是 floor_display、码恰好是 data.view_floor_board)。
// 这里只是它在页面那一侧的入口;中间件那一侧在 lib/supabase/middleware.ts 里直接问同一支函数。
//
// 【为什么别的会话一次都不多问】先看本次请求已经取过的权限码(getMyPermissions,React cache —— 根布局与页面守卫本来就取):
//   码不恰好是 [data.view_floor_board] 的会话,答案必然是"不是",不打第二次库。只有码恰好是那一个时,才去问角色那一半
//   (一个持这个码、却是经别的角色持的会话,不是大屏)。
//
// 【不读浏览器送来的任何东西】判据由会话自己的 auth.uid() 在库里求值;没有 cookie、没有请求头、没有查询参数参与。
// 【失败就抛】与 getMyPermissions 同一条:一次失败的查询不是一个"不是大屏"(lib/permissions.ts 抬头那一段)。
import { cache } from 'react'
import { createClient } from '@/lib/supabase/server'
import { getMyPermissions } from '@/lib/permissions'

export const FLOOR_BOARD_CODE = 'data.view_floor_board'

export const isFloorDisplayOnly = cache(async (): Promise<boolean> => {
    const perms = await getMyPermissions()
    if (perms.length !== 1 || perms[0] !== FLOOR_BOARD_CODE) return false
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('session_is_floor_display_only')
    if (error) throw new Error(`查询失败(session_is_floor_display_only): ${error.code ?? ''} ${error.message}`.trim())
    return data === true
})
