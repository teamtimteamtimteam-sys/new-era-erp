// app/pricing/page.tsx
// 定价板块首页:四张卡(公式 / 计价器 / 金属行情 / 每日行情录入)。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【CONV-0 ②a:本页现在是这三页【唯一的门】,所以它必须真的把门打开】★★
// ════════════════════════════════════════════════════════════════════════════
// 【发生了什么】②a 把公式 / 计价器 / 金属行情整批从工具菜单里撤掉了,理由是
// 「定价」在那张菜单上出现了两次。撤掉的前提是**这一页替它们当入口**。
//
// ★【而那个前提此前是【假的】,这是本刀实测出来的一处缺陷】★
//   撤走之前,本页第三张卡指的是 `/pricing/metal-prices/bulk`(录入),
//   金属行情【列表】只挂在卡片下方一个灰色小链接上。菜单入口一撤,
//   那个灰链接就会成为列表页【唯一】的门 ——
//   **那不是整理了一张菜单,那是把一页藏起来了。**
//   Tim 的裁定:可达(reachable)与找得到(findable)不是一回事。
//
// 【选的是"列表与录入各给一张卡",不是"把那张卡改指列表"】两条理由:
//   ① 旧注释那条道理【今天仍然成立】:每日行情录入是本板块最高频的动作,
//      不该藏在"行情"卡再点一次按钮之后。改指列表会把它降一级 ——
//      修一处可达性,弄坏一处高频路径,不划算。
//   ② ★ 而只留录入那一张卡,对一个真实角色是【一张必然被拒的卡】★
//      实测 live 授权:auditor 持有 module.pricing.view 而【没有】
//      module.pricing.edit,而 bulk 那一页由 requireEditPermission 把门。
//      也就是说撤菜单之前,审计员在这一页上看到的三张卡里,有一张点进去必然
//      是拒绝页,而他【真正读得了】的那一页藏在灰链接后面。
//      这正是 AGENTS.md「永远不要为服务端必然拒绝的动作渲染提交控件」那一族。
//      列表卡把审计员的那条路补上了(卡本身仍然照画 —— 一张卡不是提交控件,
//      而"这里有每日录入这件事"对一个只读的人也是真话)。
//
// 【灰色小链接随之删掉】列表既然自己有一张卡,再留一条指向同一页的灰链接就是
// 同一个去处的第二个入口 —— 而本刀在菜单那一侧关掉的正是这个形状。
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

// ★【一个新键都没有加】★ `pricing.pricesCard` / `pricing.pricesDesc` 本来就在
// messages 里 —— 它们是这张卡【被改指 bulk 那次】留下的孤儿键(实测:改动之前
// 全仓库没有任何地方引用它们)。本刀把那张卡接回来,顺带把这对键接回它们的用途;
// 描述改了一句,因为录入现在自己有一张卡,这一张说的就该只是列表。
const CARDS = [
    { href: '/pricing/formulas', titleKey: 'pricing.formulasCard', descKey: 'pricing.formulasDesc' },
    { href: '/pricing/calculator', titleKey: 'pricing.calculatorCard', descKey: 'pricing.calculatorDesc' },
    { href: '/pricing/metal-prices', titleKey: 'pricing.pricesCard', descKey: 'pricing.pricesDesc' },
    { href: '/pricing/metal-prices/bulk', titleKey: 'pricing.bulkCard', descKey: 'pricing.bulkDesc' },
]

export default async function PricingHubPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.pricing)
    if (denied) return denied

    const t = await getTranslations()

    return (
        <div className="p-8">
            <h1 className="text-2xl font-bold mb-4">{t('pricing.hubTitle')}</h1>

            <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
                {CARDS.map((c) => (
                    <Link
                        key={c.href}
                        href={c.href}
                        className="block border border-gray-300 rounded p-5 hover:bg-gray-50"
                    >
                        <h2 className="font-bold mb-1">{t(c.titleKey)}</h2>
                        <p className="text-sm text-gray-600">{t(c.descKey)}</p>
                    </Link>
                ))}
            </div>
        </div>
    )
}
