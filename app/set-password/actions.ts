'use server'

// app/set-password/actions.ts
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【FIX-1 item 2(2026-09-05):设完密码【去哪儿】,从浏览器搬到了服务端】★★
//
// 【被实测推翻的那句判断】委托书写着"重定向没有发生"。**它发生了。**
// 本刀在 next dev 上把两条进入路径 × 两个落点各跑了一遍(见下),
// `router.push` 每一次都真的跳了。缺的不是那一跳,是**那一跳期间屏幕上的任何证据**。
//
// 【真正的成因 —— 量出来的,不是推出来的】
// 旧写法是 `startTransition(async () => { …updateUser…; router.push(where) })`。
// `router.push` 落在一次 React transition 里,而 **transition 的语义就是:
// 新界面准备好之前,旧界面原样留在屏幕上。** 于是从"写入成功"到"/me 渲染完",
// 这一段时间里屏幕上是:
//     地址栏没动 · 两个密码框仍然填着 · 没有报错 · 按钮 disabled
// —— 也就是【一屏什么都没发生】。
//
// 实测(注入 1.2s 网络延迟,fix1-repro 账号,warehouse + 员工档案):
//     t=415ms   URL=/suppliers  pwLen=23  err=null  disabled=true
//     t=1234ms  URL=/suppliers  pwLen=23  err=null  disabled=true
//     t=2512ms  URL=/suppliers  pwLen=23  err=null  disabled=true
//     t=4047ms  URL=/suppliers  pwLen=23  err=null  disabled=true
//     t=6039ms  URL=/suppliers  pwLen=23  err=null  disabled=true
//     t=9021ms  URL=/me         pwLen=null           ← 到这里才动
// **六秒以上的空窗,而 /me 是一张读很多张表的重页面,线上冷启动只会更长。**
// Tim 看了几秒、认定没反应、又按了一次 —— 于是拿到 GoTrue 的
// 「New password should be different from the old password」。
// 那句报错【不是】第二个缺陷,它是第一次成功的回声。
//
// 【为什么改成 server action + redirect() 就能修好，而不只是换个写法】
//   ① `redirect()` 是【传输层】的跳转,不在 transition 的"等新界面"语义里;
//   ② 它顺带把**地址栏也纠正了** —— 旧路径下地址栏一直停在 /purchasing
//      (中间件的重定向发生在一次客户端导航上,Next 没有改 URL;实测复现率 100%),
//      而那正是"看起来什么都没发生"的另一半;
//   ③ 配 `useActionState` 之后,`pending` **一直真到新页面渲染完**,
//      所以那段空窗里按钮写着"保存中…"、两个输入框是禁用的 ——
//      **空窗还在(它由 /me 有多重决定),但它不再是无声的。**
//   ④ 与 /login 走同一个形状(app/login/actions.ts:63):认证类写入在服务端做,
//      结尾 `redirect()`。本仓库不该有两套。
// ════════════════════════════════════════════════════════════════════════════
import { createClient } from '@/lib/supabase/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { MIN_PASSWORD_LENGTH } from '@/lib/passwordPolicy'

// 设完密码往哪儿落。my_profile 对没关联员工档案的账号返回零行,
// 所以这一句同时回答了"这个人有没有员工档案"。
// 【不依赖任何模块权限】—— 刚被邀请的人可能一个角色都没有。
// (实测:my_profile 是属主权限视图,视图体里没有任何 has_permission —— 一个
//  角色都没有的账号照样读得到自己那一行。fix1-repro2 无档案 → /welcome、
//  fix1-repro 有档案 + warehouse → /me,两条都跑过。)
export async function landingAfterSetPassword(): Promise<string> {
    const supabase = await createClient()
    const { data } = await supabase.from('my_profile').select('employee_id').limit(1)
    return data && data.length > 0 ? '/me' : '/welcome'
}

/**
 * 表单状态。**只回错误【码】,不回句子** —— 与 /login 同一条纪律
 * (app/login/actions.ts 的那段:判据用 code,不用 message)。
 * 上游的 message 是给人读的英文散文,而且只有一种语言;
 * 码在客户端翻译,两种语言各说各的。
 */
export type SetPasswordState = { error: string | null }

export async function setPassword(
    _prev: SetPasswordState,
    formData: FormData
): Promise<SetPasswordState> {
    const password = String(formData.get('password') ?? '')
    const confirm = String(formData.get('confirm') ?? '')

    // 两条本地判据先走 —— 它们不需要往返,而且与旧的客户端版本逐字同义。
    if (password.length < MIN_PASSWORD_LENGTH) return { error: 'errTooShort' }
    if (password !== confirm) return { error: 'errMismatch' }

    const supabase = await createClient()

    // ★ 密码与强制标记【一次写完】—— 这一条从旧实现原样保住,理由没有变:
    //   分成两次的话,中间那一刻(密码已改、标记还在)只要请求失败,
    //   这个人就【永远】卡在这一页(中间件按标记把他扣住)。
    const { error } = await supabase.auth.updateUser({
        password,
        data: { must_change_password: false },
    })

    if (error) {
        // 【认不出来的一律走 errUnknown,不许现编一个原因】—— /login 那条纪律的同一处落点。
        const code = (error as { code?: string }).code
        return {
            error:
                code === 'same_password' ? 'errSamePassword'
                : code === 'weak_password' ? 'errWeak'
                : 'errUnknown',
        }
    }

    const where = await landingAfterSetPassword()
    // 外壳要重画:这个人刚刚从"被扣在设密码页"变成"可以进应用"。
    // 与 app/login/actions.ts:62 同一句,同一个理由。
    revalidatePath('/', 'layout')
    // ★ redirect() 会抛 —— 它必须留在任何 try/catch 之外,而这里正是。
    redirect(where)
}
