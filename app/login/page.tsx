// ════════════════════════════════════════════════════════════════════════════
// app/login/page.tsx
//
// 【这一页此前对"你为什么在这里"一个字都不说】(SESSION-1,2026-08-23)
//
// 它只有一条消息分支:`error=invalid`。于是一次任务中途的重定向落到这里,
// 屏幕上是一张【没有任何说明的登录表单】—— 而那与一次崩溃长得一模一样。
// SESSION-1 补上了 `reason=ended`,并把全站唯一一处硬编码中文换成了翻译键。
//
// ── LOGIN-1(2026-09-02):品牌语言 + 一条可及性地板 ─────────────────────────
//
// 【它是所有人见到的第一屏,所以顺序是「先能用,再好看」(R7)】
// 落地前实测的基线,四项全欠:
//   * 两个 <label> 【都没有 htmlFor】—— 点标签不聚焦,读屏软件念不出这是哪个框。
//     (FE-0 全仓库量到 713 个 label 里 474 个没关联,这两个在其中。)
//   * 两个 input 【都没有 autoComplete】—— 密码管理器只能靠猜。
//   * 错误只是一个 <div>,【没有 role、没有焦点】—— 而登录失败是一次【重定向】,
//     新文档里本来就存在的 live region 读屏软件通常不念。**光挂 aria-live 是假绿。**
//     处置见 LoginNotice.tsx:把焦点移过去。
//   * 【没有提交态】—— 见 SubmitButton.tsx。
//
// 【视觉语言:variant C「品牌前置」】宽松密度、品牌实心按钮、明显投影的卡片、
// 拒绝态是浅色填充片。三处刻意的偏离,都写在 docs/login-page.md §4:
//   ① 卡片投影 shadow-md → shadow-lg(它浮在一块有起伏的底上,不是白纸上);
//   ② 输入与按钮 h-8 → h-11(手机上的主操作要够得着);
//   ③ 焦点环换成实心品牌色(shadcn 的 ring-ring/50 对白底只有 1.6:1)。
//
// ★【没有水印】★ R2:螺旋球体只作为字标里那个「O」出现,不做背景、不做装饰。
// 本页用的是【完整字标】public/brand/evoltrya-wordmark.svg。
//
// 【字体只管这一页】Google Sans 由 next/font 在构建期取回并自托管,
// 通过 main 上的 --font-google-sans 作用于本页。**全站仍然是 Arial。**
// 而【Google Sans 没有中文】—— 本页默认语言是中文,所以它实际改掉的字形
// 只有「人自己打进去的邮箱」。这一条要紧,见 docs/login-page.md §5。
// ════════════════════════════════════════════════════════════════════════════
import { Google_Sans } from 'next/font/google'
import { login } from './actions'
import { safeInternalPath } from '@/lib/loginRoute'
import { getTranslations } from '@/lib/i18n/server'
import ClearRestrictedDrafts from './ClearRestrictedDrafts'
import BrandField from './BrandField'
import LoginNotice from './LoginNotice'
import SubmitButton from './SubmitButton'
import { Card, CardContent } from '@/app/components/ui/card'
import { Input } from '@/app/components/ui/input'
import { Label } from '@/app/components/ui/label'
import styles from './login.module.css'

// R6 · 只在本页加载,别的页面【连下载都不会发生】。构建期取回并自托管,
// 运行时不打 Google 的服务器,没有第三方请求。
const googleSans = Google_Sans({
    subsets: ['latin'],
    weight: ['400', '500', '700'],
    variable: '--font-google-sans',
    display: 'swap',
    fallback: ['ui-sans-serif', 'system-ui', '-apple-system', 'PingFang SC',
        'Microsoft YaHei', 'Noto Sans SC', 'sans-serif'],
})

/** 三种【确立的】拒绝。白名单 —— 认不出的 ?error= 一律当作没有。 */
const REFUSALS = ['invalid', 'unconfirmed', 'throttled'] as const
type Refusal = (typeof REFUSALS)[number]
const isRefusal = (v: string | undefined): v is Refusal =>
    !!v && (REFUSALS as readonly string[]).includes(v)

const NOTICE_ID = 'login-refusal'

export default async function LoginPage({
    searchParams,
}: {
    searchParams: Promise<{ error?: string; reason?: string; next?: string }>
}) {
    const params = await searchParams
    const t = await getTranslations()
    const refusal = isRefusal(params.error) ? params.error : null
    const sessionEnded = params.reason === 'ended'
    // 【只接内部路径】判据【只有一处定义】,见 lib/loginRoute.ts ——
    // 这里、登录动作、以及中间件那条「已登录就送进应用」用的是同一个函数。
    // (它此前在本文件与 actions.ts 里各写了一遍,注释还说「两处逐字相同」;
    //  逐字相同要靠人守,而那正是它迟早会不同的原因。)
    const next = safeInternalPath(params.next)

    // 【aria-invalid 只给 invalid 那一种】未确认与限流时,人【打进去的值是对的】——
    // 把框标成 invalid 会是同一句谎话换了一层壳:读屏软件会念「无效」,
    // 而那正是这一刀要修掉的东西。
    const fieldsInvalid = refusal === 'invalid'
    const describedBy = refusal ? NOTICE_ID : undefined

    const REFUSAL_COPY: Record<Refusal, { title: string; hint: string }> = {
        invalid: { title: t('login.errInvalid'), hint: t('login.errInvalidHint') },
        unconfirmed: { title: t('login.errUnconfirmed'), hint: t('login.errUnconfirmedHint') },
        throttled: { title: t('login.errThrottled'), hint: t('login.errThrottledHint') },
    }

    // 输入框:h-11 够得着,焦点环实心品牌色(见抬头 ③)。
    // ★【输入框边框:本来就不合格,fu2 顺手补上】★
    // shadcn 的 `border-input` 接的是 --brand-border-strong #AEBAC9,
    // 实测在【不透明白底】上只有 1.97:1 —— 也就是说【这一条在磨砂之前就破着】,
    // 而 WCAG 1.4.11 对「识别输入框所必需的视觉信息」要求 3:1。
    // 磨砂把它又压到 1.93:1,所以这一刀不能装作没看见。
    // 取 color-mix(text 55%, bg) = #7A889C,在玻璃卡面上实测 3.54:1 ✓
    // (直接用 --brand-muted-text 是 4.72:1,对一条边框来说太重了。)
    const fieldCls =
        'h-11 text-base border-[color:color-mix(in_srgb,var(--brand-text)_55%,var(--brand-bg))] ' +
        'focus-visible:ring-2 focus-visible:ring-[color:var(--brand-ocean)] ' +
        'focus-visible:ring-offset-2 focus-visible:ring-offset-[color:var(--brand-surface)]'

    return (
        <main
            className={`${googleSans.variable} ${styles.page}`}
            style={{ fontFamily: 'var(--font-google-sans)' }}
            // 机器标记,与 middleware 的 data-auth-indeterminate、moduleGuard 的
            // data-access-denied 同一条理由:靠认文案去分辨状态会漏。
            data-login-state={refusal ?? (sessionEnded ? 'ended' : 'clean')}
        >
            {/* IDLE-DRAFT:受限表单的草稿不活过一次登出 —— 见组件抬头 */}
            <ClearRestrictedDrafts />

            {/* R3/R4/R5 的那一层。装饰,aria-hidden,可整块替换 —— 见 BrandField.tsx */}
            <BrandField />

            <div className={styles.stage}>
                {/* R2 · 【完整字标】,球体只作为其中的「O」出现。
                    ★【fu2 把 alt 从 "" 改回了 "EVoltrya"】★
                    此前 <h1> 是「登录 EVoltrya OS」,名字已经被念过一遍,所以字标
                    是装饰。**现在 <h1> 换成了品牌语,整页文字里再没有出现过公司名** ——
                    字标若仍是装饰,读屏用户就【不知道这是哪个系统的登录页】。
                    换标题必须连着换这个 alt,两者是一件事。 */}
                {/* eslint-disable-next-line @next/next/no-img-element -- 矢量字标,next/image 无从优化 */}
                <img
                    src="/brand/evoltrya-wordmark.svg"
                    alt="EVoltrya"
                    className={styles.wordmark}
                />

                {/* 背景色走 inline style:shadcn 的 Card 自带 `bg-card`(不透明白),
                    两个单类选择器谁赢取决于样式表顺序 —— 那不是可以依赖的东西。
                    值本身仍然是 CSS 里那个 token,不是就地挑的数。 */}
                <Card
                    className={`${styles.card} border-[color:var(--brand-border)] shadow-lg`}
                    style={{ backgroundColor: 'var(--login-card-glass)' }}
                >
                    <CardContent className="px-6 py-7 sm:px-7">
                        {/* ★ 卡片的标题就是公司标语 ★(LOGIN-1-fu2)
                            此前这里是「登录 EVoltrya OS」+「锂电池回收 ERP 系统」,
                            而【字标就在正上方,已经说了这是哪个系统】—— 标题在重复它。
                            两行的排版规则(写死的断行、左/右对齐、共用右边缘)
                            全部写在 login.module.css 的 .slogan 抬头,那里有实测的字宽。
                            {' '} 是【给读屏软件的】:两个 span 之间没有空格的话,
                            可及名字会念成 “Powering tomorrow,recovering today.”。 */}
                        <h1 className={styles.slogan}>
                            <span className={styles.sloganLine1}>{t('login.sloganLine1')}</span>{' '}
                            <span className={styles.sloganLine2}>{t('login.sloganLine2')}</span>
                        </h1>

                        {/* 会话结束的说明排在拒绝【之前】:一个人可能先被踢出来、
                            再打错一次密码,那时两句话都该在,而"你为什么在这里"是
                            先发生的那件事。它是 role="status",【不抢焦点】。 */}
                        {sessionEnded && (
                            <LoginNotice
                                tone="info"
                                title={t('login.sessionEnded')}
                                hint={t('login.sessionEndedHint')}
                                extra={next ? t('login.returnTo', { 0: next }) : undefined}
                            />
                        )}

                        {refusal && (
                            <LoginNotice
                                tone="refusal"
                                id={NOTICE_ID}
                                title={REFUSAL_COPY[refusal].title}
                                hint={REFUSAL_COPY[refusal].hint}
                            />
                        )}

                        <form action={login} className="space-y-5">
                            {/* 中间件保住的那条路径,原样带回给动作 —— 登录之后回到人本来要去的地方。 */}
                            {next && <input type="hidden" name="next" value={next} />}

                            <div className="space-y-2">
                                <Label htmlFor="email" className="text-[color:var(--brand-text)]">
                                    {t('login.email')}
                                </Label>
                                <Input
                                    id="email"
                                    name="email"
                                    type="email"
                                    required
                                    // R7 · autoComplete="username" 是登录表单里邮箱框的那个词
                                    // (不是 "email" —— 密码管理器认的是 username/current-password 这一对)。
                                    autoComplete="username"
                                    // 手机上的四件小事:不自动大写、不自动纠错、不拼写检查、
                                    // 键盘直接给 @ 那一档,回车键印「前往」。
                                    inputMode="email"
                                    autoCapitalize="none"
                                    autoCorrect="off"
                                    spellCheck={false}
                                    enterKeyHint="next"
                                    aria-invalid={fieldsInvalid || undefined}
                                    aria-describedby={describedBy}
                                    className={fieldCls}
                                />
                            </div>

                            <div className="space-y-2">
                                <Label htmlFor="password" className="text-[color:var(--brand-text)]">
                                    {t('login.password')}
                                </Label>
                                <Input
                                    id="password"
                                    name="password"
                                    type="password"
                                    required
                                    autoComplete="current-password"
                                    enterKeyHint="go"
                                    aria-invalid={fieldsInvalid || undefined}
                                    aria-describedby={describedBy}
                                    className={fieldCls}
                                />
                            </div>

                            <div className="pt-1">
                                <SubmitButton
                                    label={t('login.submit')}
                                    pendingLabel={t('login.submitting')}
                                />
                            </div>
                        </form>

                        {/* ★【这一行本来在卡片【外面】,浮在底图上 —— 实测 4.12:1,不合格】★
                            --brand-muted-text 压在底图最暗处只有 4.12:1,而正文要 4.5:1。
                            这是【量出来的,不是看出来的】:那块底色淡得像白的,肉眼根本
                            分不出 4.12 与 4.83 的差别 —— 这一条正是 R4 要求「测,别用眼估」的理由。

                            处置不是把底图再调亮一点(那要靠一个「够亮了」的判断,而下一个
                            改底图的人不会知道有这么一条约束挂在上面),而是【定一条不变量】:
                            ★ 底图上只有字标,一个字都不放。凡是要被读的,都在不透明的卡片上。★
                            于是底图的明暗以后怎么调,都不可能把某一句话调到不合格 ——
                            约束由【结构】守住,不由数值守住。
                            字标是唯一的例外,而它是【标识】:WCAG 1.4.3 明文把 logotype
                            排除在 4.5:1 之外;它仍然过了 1.4.11 图形元素的 3:1(实测 3.30:1)。 */}
                        <p
                            className="mt-6 border-t pt-4 text-center text-[13px]"
                            style={{ borderColor: 'var(--brand-border)', color: 'var(--brand-muted-text)' }}
                        >
                            {t('login.noAccount')}
                        </p>
                    </CardContent>
                </Card>
            </div>
        </main>
    )
}
