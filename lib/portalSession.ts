// lib/portalSession.ts
// MES-9a(2026-10-19,MES-9 Step 0 Q10 · Q11,Tim):【这个请求的会话是不是一个供应商门户会话】—— 服务端判,一次请求只判一次。
//
// 判据是【令牌里的 role】(supplier_portal —— Supabase Auth 的 access token hook 写进去的,PostgREST 照它切数据库角色),
//   取自本次请求的会话 cookie(中间件刚刚用 getUser() 让认证服务验过它)。不打库:一个门户会话调不了 current_user_permissions,
//   而根布局必须在调用任何员工那一面的东西【之前】就知道它是谁。
// 【不读浏览器送来的别的东西】没有查询参数、没有自定义请求头参与;解不出 role = 不是门户会话。
// 【这不是安全边界】边界在库里(门户角色只够得着按名授给它的东西,判词八);这里让路由那一层两边看得见地走不进对方的屏幕。
import { cache } from 'react'
import { createClient } from '@/lib/supabase/server'
import { tokenRoleOf, PORTAL_DB_ROLE } from '@/lib/loginRoute'

export const getSessionRole = cache(async (): Promise<string | null> => {
    const supabase = await createClient()
    const { data } = await supabase.auth.getSession()
    return tokenRoleOf(data.session?.access_token)
})

export const isPortalSession = cache(async (): Promise<boolean> => (await getSessionRole()) === PORTAL_DB_ROLE)
