'use server'

// app/set-password/actions.ts
import { createClient } from '@/lib/supabase/server'

// 设完密码往哪儿落。my_profile 对没关联员工档案的账号返回零行,
// 所以这一句同时回答了"这个人有没有员工档案"。
// 【不依赖任何模块权限】—— 刚被邀请的人可能一个角色都没有。
export async function landingAfterSetPassword(): Promise<string> {
    const supabase = await createClient()
    const { data } = await supabase.from('my_profile').select('employee_id').limit(1)
    return data && data.length > 0 ? '/me' : '/welcome'
}
