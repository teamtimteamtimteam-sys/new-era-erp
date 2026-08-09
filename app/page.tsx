import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'
import { SECTIONS } from '@/lib/modules'
import { getVisibleModules } from '@/lib/moduleAccess'

// OPS-15:模块卡片不再是本文件里手写的一份清单 —— 与导航条共用 lib/modules.ts。
// 【内容没有变】分组、组内顺序、文案键与改造前逐张一致(任务板改造前就不出卡片,
// 现在由 section: null 明写)。变的只有一件事:【进不去的模块不再出卡片】。
//
// 藏掉入口是体贴,不是边界 —— 真正的拒绝在每个页面自己的 requireModule()
// (app/components/moduleGuard.tsx),边界在数据库。
//
// 这一页【仍然是链接目录,不是仪表盘】。换成仪表盘是下一切次:两件事一起做,
// 把关就没法单独审。

// 【「我的」两张卡片写在这里,而不是 lib/modules.ts —— 这是有意的】
// lib/modules.ts 是【模块清单】:每一行都带一个 module.<x>.view 权限码,并且
// moduleForPath() 用它把子路由映射到守卫上。/me 与 /my-reviews 【按设计不属于任何模块】:
//   * /me 是每一个登录用户自己的档案,不需要任何权限判断;
//   * /my-reviews 靠的是"我是这一行的评估人"那条【行级】策略,不是任何 HR 模块权限 ——
//     它是 /hr 的同级,挂进 HR 模块等于对部门经理隐身。
// 把它们塞进 MODULES 就得给它们编一个模块码,而那个码要么恒真(等于谎称有把关),
// 要么把两页收进某个模块(等于给它们加了一道设计上不该有的门)。所以它们在这里
// 【无条件渲染】,与 NavLinks.tsx 的 SELF_ITEMS 同一条理由、同一个顺序。
//
// 后果就是这次要修的那件事:employee 角色零模块权限,过滤后一张模块卡都不剩 ——
// 而这两页【正是那个角色的全部产品】,首页却不给入口。
const SELF_CARDS = [
    { href: '/my-reviews', titleKey: 'home.myReviewsTitle', descKey: 'home.myReviewsDesc' },
    { href: '/me', titleKey: 'home.meTitle', descKey: 'home.meDesc' },
]

const CARD_CLASS =
    'border border-gray-300 rounded-lg p-6 hover:bg-gray-50 hover:border-gray-400 transition block'

export default async function Home() {
    const t = await getTranslations()
    const visible = await getVisibleModules()

    return (
        <div className="p-8 max-w-4xl">
            <h1 className="text-2xl font-bold mb-2">Evoltrya OS</h1>
            <p className="text-gray-600 mb-8">{t('home.subtitle')}</p>

            {/* 一个模块都进不去时,同样【说出来】。
                注意这条横幅说的是"没有模块权限",不是"这一页是空的"—— 自从「我的」
                两张卡片无条件渲染,首页对 employee 已经不再是一片空白。横幅仍然要有:
                否则那个人只看见两张卡,分不清"我只有这些"与"其余的没加载出来"。 */}
            {visible.length === 0 && (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded max-w-2xl mb-8">
                    <p className="font-medium">{t('home.noModules')}</p>
                    <p className="text-sm mt-1">{t('home.noModulesHint')}</p>
                </div>
            )}

            {SECTIONS.map((section) => {
                const cards = visible.filter((m) => m.section === section.id)
                if (cards.length === 0) return null
                return (
                    <div key={section.id} className="mb-8">
                        <h2 className="text-lg font-semibold mb-4">{t(section.titleKey)}</h2>
                        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
                            {cards.map((card) => (
                                <Link key={card.href} href={card.href} className={CARD_CLASS}>
                                    <h3 className="font-semibold text-lg mb-1">{t(card.titleKey)}</h3>
                                    <p className="text-sm text-gray-600">{t(card.descKey)}</p>
                                </Link>
                            ))}
                        </div>
                    </div>
                )
            })}

            {/* 【无条件】—— 没有 visible.filter,也没有任何权限判断。见上面 SELF_CARDS 的理由。
                放在模块分组之后,与导航条的顺序一致(模块在前,「我的」在后)。 */}
            <div className="mb-8">
                <h2 className="text-lg font-semibold mb-4">{t('home.sectionSelf')}</h2>
                <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
                    {SELF_CARDS.map((card) => (
                        <Link key={card.href} href={card.href} className={CARD_CLASS}>
                            <h3 className="font-semibold text-lg mb-1">{t(card.titleKey)}</h3>
                            <p className="text-sm text-gray-600">{t(card.descKey)}</p>
                        </Link>
                    ))}
                </div>
            </div>
        </div>
    )
}
