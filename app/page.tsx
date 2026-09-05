// app/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-6 ②③(2026-09-04)· 首页只剩一件东西:一个【还不能用】的搜索外壳
// ════════════════════════════════════════════════════════════════════════════
//
// 【这一页的来历,三刀连起来看才读得懂】
//   OPS-18(Phase 6)把它从链接目录换成【运营看板】:35 块一样大的牌子。
//   CONV-7 ① 把那整块搬去 /tools/reminders,只留下三条链接与「我的」两张卡。
//   **CONV-6 ② 把剩下的也删了。** Tim 逐条点名:两行标题、月结枢纽、
//   「我的」那一节连同两张卡 —— 全部删掉。
//
// ★【删掉的每一样,以及它去哪了 —— 一处都不许是"就这么没了"】★
//   · 「EVoltrya OS」+「Lithium Battery Recycling ERP」两行标题
//        → **顶栏左上角那个字标已经在说这是哪套系统**(app/components/TopNav.tsx)。
//          在系统内部的每一页顶上再说一遍,是把一张工作台当成落地页在做。
//   · 月结枢纽那条链接
//        → /finance/month-end 在财务菜单的「期末」组里有自己的条目;
//          CONV-7 的财务 Overview 底下也给了它一条链接。**两个入口都还在。**
//   · 「我的」两张卡(/me · /my-reviews)
//        → ★ 这一条必须核过才能删,而本刀核了 ★:两页在顶栏右侧「关于你」
//          那一区各有一条链接(TopNav 第 117 / 120 行),手机上收在模块抽屉
//          底部的「关于你」一段(ModuleBar 第 385 / 392 行)。
//          **删掉卡片没有让任何一页失去入口。**
//          ★【一处照直报出来的缺口,不是本刀造成的】★ /my-reviews 那条链接是
//          `lg:inline`,而抽屉是 `sm:hidden` —— 于是在 **640px ≤ 宽 < 1024px**
//          这一段里,它在顶栏上不画、在抽屉里也到不了。首页那张卡此前是这段
//          宽度上的唯一入口。**这不是删卡造成的错,是删卡【暴露】出来的错**,
//          它在报告里单列一条。(/me 是 sm:inline,不在这个缺口里。)
//   · CONV-7 加的那条「提醒」链接
//        → **本刀一并删掉,而这是一处判断,写下来免得被当成手滑。**
//          Tim 的裁定原文是「首页只剩一件东西:搜索框」;而 ① 删 dock 的
//          理由(二级菜单已经足够直接)对它逐字成立 —— 提醒在工具菜单里有
//          自己的条目。CONV-7 给它的理由是「可达 ≠ 找得到,第一周每个人都要
//          问一次它去哪了」,那条理由今天仍然有分量,**所以它是本刀最可能
//          被 Tim 推翻的一处**,报告里单列。
//
// ★【留下的两样,以及为什么它们不违反"只剩一件东西"】★
//   ① 搜索外壳 —— 那件东西本身(③);
//   ② 零模块权限的那句话 —— 它不是内容,是【关于这个账号的一句解释】,
//      而且只对那种账号渲染。CONV-7 ① 刚把它从一处死代码修活(判据从
//      「every(!allowed)」换成「一个 module.* 都不持有」,因为工具名下三条
//      恒真条目让前者【永远是 false】)。★ 本刀确认那个修复仍然成立 ★:
//      ① 删掉的 dock 不参与这个判据;它读的是 getMyPermissions() 的原始码表,
//      与模块可进性无关。而这一页越空,这句话越是那种账号【唯一】的解释 ——
//      所以它必须在这里,并且必须在搜索框【上面】(先说明状况,再给工具)。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【③ 搜索外壳:本刀只做【形状】,内容与行为是 A 刀的活】★★
// ════════════════════════════════════════════════════════════════════════════
//
// 【Tim 的判据,逐字】**首页不要那么严肃、那么像在催你干活。**
//   他认可的三个方向,没有一个需要新能力:
//     · 留白而不是填满 —— 这一条由【删】达成,不由设计达成;
//     · 语气轻一点,不要临床感 —— 圆角、柔和的投影、一句人话的提示;
//     · 一个小的、慢慢动的东西,让近乎空白的页证明自己是活的而不是坏的
//       —— 见 app/home.module.css 的 .pulse,那里写着它为什么过得了
//          BASE-1 的 R1(动效只反馈状态,永不装饰)。
//
// ★【它【不许】假装能用 —— 这是 Tim 的明令,也是本页唯一的技术判断】★
//   实现是 <details>/<summary>,不是 <input>:
//     · 一个接了 input 的框会【吞掉打进去的字】。打了字、按了回车、什么都没
//       发生 —— 那是这套系统反复在修的那一类谎的完整形状;
//     · <summary> 点下去就展开那句实话,**纯 HTML**:不需要 'use client'、
//       不需要 state、键盘天然可达、读屏读成一个可展开的按钮;
//     · 右边还挂一个「尚未启用」的标记,**让实话在点之前也在屏幕上** ——
//       没有人应该先打完一句话才发现它不通。
//
// 【手机(390px)的处理,照直说】整页单列居中,框宽 = 视口 − 2rem 的边距;
//   框内三样东西一行放得下(放大镜 1.15rem + 提示语 + 标记),
//   ★ 收缩时【截断的是提示语,不是那个标记】★ —— 被挤掉的正好会是
//   "它还不能用"那句话,而那是这个框最要紧的一句。规则写在 .prompt 上。
//   <420px 另有一档:内边距与字号各降一级,那一点的位置抬高,避免它压到框上。
// ════════════════════════════════════════════════════════════════════════════
import { getTranslations } from '@/lib/i18n/server'
import { getMyPermissions } from '@/lib/permissions'
import { getTodaysDoodle } from '@/lib/festivalDoodle'
import { getHomeGreeting } from '@/lib/homeGreeting'
import HomeMark from '@/app/components/home/HomeMark'
import RememberGreeting from '@/app/components/home/RememberGreeting'
import styles from './home.module.css'

export default async function Home() {
    const t = await getTranslations()
    const perms = await getMyPermissions()
    // ★【UI-1b】两样新东西,各自可以【缺席】而不留下痕迹 ★
    //   · doodle === null  → 今天不是节日窗口,画平日字标。**绝大多数日子如此,
    //                        这不是一次失败。**
    //   · greeting === null → 这个账号没有员工档案(或问候语表是空的)。
    //                        **整行不画** —— 不编一个占位名,也不拿邮箱当名字。
    //                        与 UI-1a 的 AvatarMenu.tsx:47-56 是同一条判据。
    const doodle = await getTodaysDoodle()
    const greeting = await getHomeGreeting()

    // 【判据一个字没动 —— CONV-7 ① 定的那一条】他一个 module.* 权限都没有。
    // 它绕开的是"工具名下三条恒真条目让 tools.allowed 对每个人都为 true"那个陷阱;
    // 本刀删掉 dock 不影响它(dock 从不参与这个判断)。
    const noModulePermission = !perms.some((p) => p.startsWith('module.'))

    return (
        <div className={styles.stage}>
            {/* 【活性指示,不是装饰】—— 理由整段写在 home.module.css 的 .pulse 抬头。 */}
            <span className={styles.pulse} aria-hidden="true" />

            {/* ★【UI-1b ①:字标,搜索框【上面】】★
                Tim 的裁定:用 public/brand/evoltrya-wordmark.svg【原样】——
                它是唯一的彩色资产,3.40:1,BRAND-1 逐像素校过色。
                **不与球体合成**(LOGIN-1:界面里球体只作字标里那个「O」出现)。
                节日窗口里它换成同一个画框里的一张节日画;顶栏那个黑色标记
                【永远不换】。整段理由在 app/components/home/HomeMark.tsx。 */}
            <HomeMark doodle={doodle} />

            {/* 零模块权限时说出来(OPS-15)。**这一页越空,它越是唯一的解释。**
                放在搜索框【上面】:先说清这个账号的状况,再递工具。
                【UI-1b 没有动它的位置】字标在它上面,而字标不是"工具" —— 
                "先说明状况,再递工具"这条顺序一个字没变。 */}
            {noModulePermission && (
                <div
                    className="rounded-[var(--brand-radius)] border border-amber-300 bg-amber-50 px-4 py-3 text-amber-900 max-w-2xl text-left"
                    data-home-no-modules="1"
                >
                    <p className="font-medium">{t('home.noModules')}</p>
                    <p className="text-sm mt-1">{t('home.noModulesHint')}</p>
                </div>
            )}

            {/* ── 搜索外壳:形状是本刀的,内容与行为是 A 刀的 ─────────────── */}
            <details className={styles.shell} data-home-search="shell">
                <summary className={styles.box}>
                    <svg
                        className={styles.glyph}
                        viewBox="0 0 20 20"
                        fill="none"
                        stroke="currentColor"
                        strokeWidth="1.6"
                        aria-hidden="true"
                    >
                        <circle cx="8.75" cy="8.75" r="5.25" />
                        <path d="M12.6 12.6 L16.5 16.5" strokeLinecap="round" />
                    </svg>
                    <span className={styles.prompt}>{t('home.searchPrompt')}</span>
                    {/* 【点之前就说一次】见文件抬头。 */}
                    <span className={styles.badge} data-home-search="badge">
                        {t('home.searchNotYetBadge')}
                    </span>
                </summary>
                {/* 【点之后说完整的一句】—— 说的是"还没建",不是"出错了"。 */}
                <p className={styles.note} data-home-search="note">
                    {t('home.searchNotYet')}
                </p>
            </details>

            {/* ★【UI-1b ①:问候语,搜索框【下面】】★
                Tim 写下的目的是五个字:**给首页增加一些温度。**
                所以它在搜索框【下面】—— 它不是这一页要你做的事,是这一页
                对你说的一句话。字号比正文大一点点、颜色走 --brand-muted-text,
                **刻意不显眼**:它不许与字标或搜索框抢。
                句子住在 home_greetings 表里(改一句不用部署),时段按【新加坡】
                的钟算(lib/homeGreeting.ts),每次重挑且不与上一句相同。 */}
            {greeting && (
                <p className={styles.greeting} data-home-greeting={greeting.id}>
                    {greeting.text}
                    {/* 把这一句记下来,好让下一次排除它。渲染 null。 */}
                    <RememberGreeting id={greeting.id} />
                </p>
            )}
        </div>
    )
}
