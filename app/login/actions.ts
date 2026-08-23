'use server'

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'

export async function login(formData: FormData) {
    const email = formData.get('email') as string
    const password = formData.get('password') as string
    // SESSION-1:中间件把人踢出来时保住了原路径(`?next=`),登录页把它带了回来。
    // 保住一条路径却不用它,等于没保住 —— 人还是得自己走回去。
    const nextRaw = formData.get('next')
    // 【只接内部路径】—— `//host` 与绝对 URL 一律丢掉,否则这个参数是一个开放重定向。
    // 判据与 app/login/page.tsx 里那一句逐字相同,两处都会被人读到。
    const next =
        typeof nextRaw === 'string' && nextRaw.startsWith('/') && !nextRaw.startsWith('//')
            ? nextRaw
            : null

    const supabase = await createClient()

    const { error } = await supabase.auth.signInWithPassword({ email, password })

    if (error) {
        // 失败时把 next 一起带回去,否则第一次打错密码就把"回到哪儿"弄丢了。
        const qs = new URLSearchParams({ error: 'invalid' })
        if (next) qs.set('next', next)
        redirect(`/login?${qs.toString()}`)
    }

    revalidatePath('/', 'layout')
    redirect(next ?? '/suppliers')
}
