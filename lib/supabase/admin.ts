import 'server-only'

// lib/supabase/admin.ts
// 【service role 客户端】—— 只用于 auth.admin.*(目前只有邀请)。
//
// ════════════════════════════════════════════════════════════════════════════
// 【这把钥匙绝不能进浏览器】。service role 绕过 RLS,拿到它等于拿到整个数据库。
// 三道防线,缺一不可:
//
//   1. 文件顶部的 import 'server-only' —— 任何客户端组件(直接或间接)引入本文件,
//      【构建就会失败】,而不是等到运行时才出事。这是最要紧的一道。
//   2. 环境变量名【不带 NEXT_PUBLIC_ 前缀】。Next.js 只把 NEXT_PUBLIC_* 注入客户端
//      包,所以 SUPABASE_SERVICE_ROLE_KEY 不可能被打进浏览器 bundle。
//   3. 调用它的 server action 自己再查一次 action.manage_permissions —— 就算前两道
//      都被绕过,没有权限的人也发不出邀请。
//
// 【不要】在这里做业务查询。业务数据一律走 lib/supabase/server.ts 的 anon 客户端,
// 让 RLS 与前面四个切次建立的整套权限继续生效。service role 一旦用来读业务数据,
// 前面所有的策略就都被架空了。
// ════════════════════════════════════════════════════════════════════════════
import { createClient } from '@supabase/supabase-js'

export function createAdminClient() {
    const key = process.env.SUPABASE_SERVICE_ROLE_KEY
    if (!key) {
        // 说清楚缺什么、加在哪里 —— 这个错误只有部署的人能修
        throw new Error(
            'SUPABASE_SERVICE_ROLE_KEY is not set. Add it to .env.local for local ' +
                'development and to the Vercel project environment for deployments. ' +
                'It is the Supabase service_role key from Project Settings → API.'
        )
    }
    return createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, key, {
        auth: { autoRefreshToken: false, persistSession: false },
    })
}
