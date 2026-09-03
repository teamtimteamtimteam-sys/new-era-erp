// app/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-7 ①(2026-09-04)· 首页安静下来 —— 看板整块搬去 /tools/reminders
// ════════════════════════════════════════════════════════════════════════════
//
// 【此前它是什么】OPS-18(Phase 6)把首页从【链接目录】换成【运营看板】:
// 34 支 + HR 一块 = 35 块一样大的牌子,一事一牌。那一步在当时是对的 ——
// 它治的是"两个首页并存,而人落地的是错的那一个"。
//
// 【为什么现在整块搬走 —— Tim 的裁定,2026-09-04,不要重开】
//   信号【天生跨模块】,所以拆回各自的模块会丢掉"一眼看完所有该操心的事"这件事
//   本身。给它们一个【自己的去处】,人就是想看的时候去看,而不是一登录就被推一脸。
//   **那正是这一页得以安静下来的前提。**
//   实测支撑这个判断:34 支里【只有 12 支有行】,另外 22 支为零 ——
//   也就是说登录第一屏三分之二的面积说的都是「没有事」。
//
// 【搬走的是什么,一个字不多】「当前待办」那一整节:34 块支牌 + HR 那一块。
//   连同它们的三条规矩(0 不冒充受限 · 一块一扇门 · 每个信号过 mustRows)、
//   门牌清单、以及 ap_over_90 / awaiting_assay 那两处"给行一张脸"的补查,
//   全部原样迁到 lib/reminders.ts 与 app/tools/reminders/page.tsx。
//   **本页因此不再读 operations_now,也不再读 hr_alerts。**
//
// ★【留下的是什么,以及为什么】★
//   ① 零模块权限的那句话(OPS-15)—— 它不是信号,是一个【关于这个账号】的事实,
//      而说这句话最该的地方就是他落地的第一屏。
//   ② 月结枢纽那条链接 —— 它【本来就不复制任何信号】(注释里白纸黑字),
//      所以它不属于被搬走的那一类。安静指的是不推数字,不是不给路。
//   ③ ★【新增一条:提醒】★ 与 ② 同一种东西 —— 一条【不带任何数字】的链接。
//      理由是 CONV-0 在 /pricing 上裁过的那条区别:**可达(reachable)与
//      找得到(findable)不是一回事。** 提醒在工具菜单里有自己的条目,所以它可达;
//      而这一页是所有人过去【一直用来看待办的地方】,不留一条路,第一周每个人
//      都要问一次"它去哪了"。这条链接不印任何计数 —— 它不推,它只指路。
//   ④ 「我的」两张卡 —— 不受模块把关,人人可见(OPS-15:employee 角色的全部
//      产品恰恰是这两页,首页必须给入口)。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'
import { getMyPermissions } from '@/lib/permissions'
import { allows } from '@/lib/modules'

// 「我的」两张卡片:不受模块把关,人人可见 —— 理由与顺序同 NavLinks 的 SELF_ITEMS。
const SELF_CARDS = [
    { href: '/my-reviews', titleKey: 'home.myReviewsTitle', descKey: 'home.myReviewsDesc' },
    { href: '/me', titleKey: 'home.meTitle', descKey: 'home.meDesc' },
]

export default async function Home() {
    const t = await getTranslations()
    const perms = await getMyPermissions()

    // ★★【CONV-7 ①:这一句的判据换了,而【换它的理由是它此前【永远不成立】】★★
    //
    // 【原样】`(await getModuleAccess()).every((m) => !m.allowed)`。
    // 【实测(浏览器,零权限账号,2026-09-04):它渲染 0 次。】
    //   一个模块的 allowed 是【它名下有没有任何一条二级条目进得去】推导出来的,
    //   而「工具」名下有三条判据恒真的条目(日历 · 单位换算 · 提醒)——
    //   **于是 tools.allowed 对每一个登录用户都是 true,这个 every() 永远是 false。**
    //   它从 TOOLS-1 给换算器写下 `{ all: [] }` 那天起就是死代码,而
    //   **没有任何检查看得见一句"永远不显示的话"。**
    //
    // ★【为什么这一刀必须修它,而不是记一笔了事】★
    //   在这一刀之前,一个零权限的人至少还看得见 35 块写着「受限」的牌子 ——
    //   那是一种笨拙的解释,但它是一种解释。**牌子搬走之后,这一页对他就只剩
    //   标题、两条链接和「我的」两张卡** —— 一页什么都没解释的页面。
    //   也就是说:是【本刀】把一处沉默的死代码变成了一处会被人撞上的沉默。
    //
    // 【新判据:他一个 module.* 权限都没有】—— 这正是那句话的字面意思
    //   (「你还没有任何模块的权限」),而且它绕开了上面那个"工具人人可进"的陷阱:
    //   工具不由 module.* 码把门,所以它不会再把这句话吞掉。
    //   持有 module.tasks.view 之类【任何一个】模块码的人不会看到它,那是对的。
    const noModulePermission = !perms.some((p) => p.startsWith('module.'))

    // 【一条不带数字的链接的画法 —— 两条共用一个,免得它们各自漂开】
    const plainLink = (href: string, title: string, desc: string) => (
        <Link
            href={href}
            className="inline-block rounded-[var(--brand-radius)] border px-4 py-3 transition hover:opacity-90"
            style={{ borderColor: 'var(--brand-border)', background: 'var(--brand-surface)' }}
        >
            <span className="font-semibold" style={{ color: 'var(--brand-text)' }}>
                {title}
            </span>
            <span className="text-sm ml-2" style={{ color: 'var(--brand-muted-text)' }}>
                {desc}
            </span>
        </Link>
    )

    return (
        <div className="p-4 sm:p-8 max-w-5xl">
            <h1 className="text-2xl font-bold mb-2">EVoltrya OS</h1>
            <p className="mb-8" style={{ color: 'var(--brand-muted-text)' }}>
                {t('home.subtitle')}
            </p>

            {/* 零模块权限时说出来(OPS-15)—— 否则一张什么都没有的首页与"系统坏了"分不开。
                【这句话此前的作用更强,现在更强了】从前它旁边还有 35 块「受限」牌子,
                多少算个旁证;现在这一页本来就安静,它是【唯一】的解释。 */}
            {noModulePermission && (
                <div
                    className="rounded-[var(--brand-radius)] border border-amber-300 bg-amber-50 px-4 py-3 text-amber-900 max-w-2xl mb-8"
                    data-home-no-modules="1"
                >
                    <p className="font-medium">{t('home.noModules')}</p>
                    <p className="text-sm mt-1">{t('home.noModulesHint')}</p>
                </div>
            )}

            {/* ── 两条【不带数字】的路 ─────────────────────────────────────── */}
            <div className="flex flex-col sm:flex-row flex-wrap gap-3 mb-8 items-start">
                {/* 提醒:人人可进(每一支按它自己家的模块把关),所以这条链接无条件画。
                    与 /tools/calendar 同一条理由 —— 本页不替它判,它自己判。 */}
                {plainLink('/tools/reminders', t('reminders.title'), t('home.remindersDesc'))}

                {/* 月结枢纽:纯链接、不复制信号(信号归 /finance/month-end 自己)。
                    没有数字可遮,所以无权时按 OPS-15 的方式【不渲染】而不是画「受限」。 */}
                {allows('module.finance.view', perms) &&
                    plainLink('/finance/month-end', t('dashboard.monthEnd'), t('dashboard.monthEndDesc'))}
            </div>

            {/* 「我的」—— 无条件渲染,见 SELF_CARDS 的注释 */}
            <div className="mb-8">
                <h2 className="text-lg font-semibold mb-4">{t('home.sectionSelf')}</h2>
                <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
                    {SELF_CARDS.map((card) => (
                        <Link
                            key={card.href}
                            href={card.href}
                            className="rounded-[var(--brand-radius)] border p-6 transition hover:opacity-90 block"
                            style={{ borderColor: 'var(--brand-border)', background: 'var(--brand-surface)' }}
                        >
                            <h3 className="font-semibold text-lg mb-1" style={{ color: 'var(--brand-text)' }}>
                                {t(card.titleKey)}
                            </h3>
                            <p className="text-sm" style={{ color: 'var(--brand-muted-text)' }}>
                                {t(card.descKey)}
                            </p>
                        </Link>
                    ))}
                </div>
            </div>
        </div>
    )
}
