// app/login/page.tsx
//
// 【这一页此前对"你为什么在这里"一个字都不说】(SESSION-1,2026-08-23)
//
// 它只有一条消息分支:`error=invalid`。于是一次任务中途的重定向落到这里,
// 屏幕上是一张【没有任何说明的登录表单】—— 而那与一次崩溃长得一模一样。
// 人打过的字没了、也没人告诉他为什么。十三个账号即将发出去,而这是他们
// 见到的第一屏。
//
// 【三种到达方式,三种说法,不许混成一种】
//   1. 直接来登录        → 什么提示都没有(对的)
//   2. 邮箱或密码错       → errInvalid
//   3. 会话【确立地】结束 → sessionEnded。**只有中间件真的问到了答案才会带
//      `reason=ended` 过来**;它问不到答案的那一种走 503 那一页,到不了这里
//      (见 lib/supabase/middleware.ts 抬头)。所以这句话是有依据的,不是猜的。
//
// 【本页此前也是全站唯一一处硬编码中文的页面】,而且标题写着一个这个系统
// 已经不再使用的名字(SWM-OS)。两处一并改掉:实测全仓库 `SWM-OS` 只有 4 处、
// 3 个文件,其中只有这一处是【人看得见的】;另外三处是一次性测试账号地址
// `admin@swm-os.test`,那是一个真实标识,不能改。
import { login } from './actions'
import { getTranslations } from '@/lib/i18n/server'

export default async function LoginPage({
    searchParams,
}: {
    searchParams: Promise<{ error?: string; reason?: string; next?: string }>
}) {
    const params = await searchParams
    const t = await getTranslations()
    const hasError = params.error === 'invalid'
    const sessionEnded = params.reason === 'ended'
    // 【只接内部路径】—— `//host` 与绝对 URL 一律丢掉,否则这个参数就是一个开放重定向。
    const next =
        params.next && params.next.startsWith('/') && !params.next.startsWith('//')
            ? params.next
            : null

    return (
        <main className="min-h-screen flex items-center justify-center bg-gray-50 p-4">
            <div className="w-full max-w-md bg-white border border-gray-300 rounded-lg p-8 shadow-sm">
                <div className="mb-6 text-center">
                    <h1 className="text-2xl font-bold">{t('login.title')}</h1>
                    <p className="text-sm text-gray-500 mt-1">{t('login.subtitle')}</p>
                </div>

                {/* 会话结束的说明排在密码错误【之前】:一个人可能先被踢出来、
                    再打错一次密码,那时两句话都该在,而"你为什么在这里"是先发生的那件事。 */}
                {sessionEnded && (
                    <div
                        data-session-ended="1"
                        className="mb-4 bg-amber-50 border border-amber-300 text-amber-900 text-sm px-3 py-2 rounded"
                    >
                        <p className="font-medium">{t('login.sessionEnded')}</p>
                        <p className="mt-1">{t('login.sessionEndedHint')}</p>
                        {next && <p className="mt-1 text-xs">{t('login.returnTo', { 0: next })}</p>}
                    </div>
                )}

                {hasError && (
                    <div className="mb-4 bg-red-50 border border-red-200 text-red-700 text-sm px-3 py-2 rounded">
                        {t('login.errInvalid')}
                    </div>
                )}

                <form action={login} className="space-y-4">
                    {/* 中间件保住的那条路径,原样带回给动作 —— 登录之后回到人本来要去的地方。 */}
                    {next && <input type="hidden" name="next" value={next} />}
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('login.email')}</label>
                        <input
                            type="email"
                            name="email"
                            required
                            placeholder={t('login.email')}
                            className="w-full border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>

                    <div>
                        <label className="block text-sm font-medium mb-1">{t('login.password')}</label>
                        <input
                            type="password"
                            name="password"
                            required
                            placeholder={t('login.password')}
                            className="w-full border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>

                    <button
                        type="submit"
                        className="w-full bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                    >
                        {t('login.submit')}
                    </button>
                </form>

                <p className="mt-4 text-center text-xs text-gray-500">{t('login.noAccount')}</p>
            </div>
        </main>
    )
}
