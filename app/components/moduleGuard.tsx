// app/components/moduleGuard.tsx
// 【进不去的页面必须说出来,而不是渲染成空的】
//
// 这是 OPS-15 之前全站最普遍的一处谎:没有某个模块权限的人打开该模块任意一页,
// RLS 返回【零行】,mustRows 正确地不为空集抛错,于是页面渲染出一张空表 ——
// 屏幕上"你没有权限"与"确实还没有数据"长得一模一样。live 的 employee 角色一个模块
// 权限都没有,却看得见完整导航,点进去每一页都是"暂无数据"。
//
// 这与 lib/permissions.ts 存在的理由是同一条,只是高了一层:那边分辨【遮蔽的 null】
// 与【本来就没有的 null】,这边分辨【进不去的空】与【真的空】。
//
// 【为什么在页面里而不是 layout 里】Next 16 自己的文档写着:因为 Partial Rendering,
// layout 在客户端导航时【不会重新渲染】,所以放在 layout 的检查不会在每次路由切换时
// 执行;并且"在 layout 里 return null"被明确列为 not recommended —— 应用有多个入口,
// 挡不住嵌套路由段。文档给的做法就是本文件:检查放在页面组件里,贴着取数那一层。
// (node_modules/next/dist/docs/01-app/02-guides/authentication.md《Layouts and auth checks》)
//
// 【这不是安全边界】。边界在数据库:RLS + 遮蔽视图 + 函数里的 require_permission。
// 就算这里漏了一页,那一页也只会是空的、改不动任何东西 —— 与 settings/permissions/guard.ts
// 同样的定位,本文件是它的通用化。
import Link from 'next/link'
import { canEnterModule } from '@/lib/moduleAccess'
import { getTranslations } from '@/lib/i18n/server'
import type { ModuleEntry } from '@/lib/modules'

/** 两种拒绝共用的那一块屏 —— 措辞不同,形状必须相同。 */
async function refusal(titleKey: string, deniedKey: string, hintKey: string) {
    const t = await getTranslations()
    return (
        <div className="p-8 max-w-2xl">
            <h1 className="text-2xl font-bold mb-4">{t(titleKey)}</h1>
            <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded">
                <p className="font-medium">{t(deniedKey)}</p>
                <p className="text-sm mt-1">{t(hintKey)}</p>
            </div>
            <Link href="/" className="inline-block mt-4 text-sm text-blue-600 hover:underline">
                {t('common.backHome')}
            </Link>
        </div>
    )
}

/**
 * 用法(每个受模块管辖的页面的第一行):
 *     const denied = await requireModule(MOD.finance)
 *     if (denied) return denied
 * 放在【任何查询之前】—— 拒绝要来自权限判断,不能是从空结果倒推出来的。
 */
export async function requireModule(mod: ModuleEntry) {
    if (await canEnterModule(mod.permission)) return null
    return refusal(mod.navKey, 'common.moduleDenied', 'common.moduleDeniedHint')
}

/**
 * 【有些页面属于两个模块,不是一个】
 *     const denied = await requireAnyModule([MOD.finance, MOD.processing])
 *     if (denied) return denied
 *
 * requireModule 问的是【那一个】模块;本函数问【任意一个】。它存在的理由与
 * db/views/batch_margin.sql 的谓词是同一条:收入在财务、分摊成本在加工,而
 * 【没有任何 live 角色同时持有两个模块】—— 用单模块把关,这一页就会对它该服务的
 * 两拨人各挡掉一拨。OR 就是要点(AGENTS.md 常设决定 2)。
 *
 * 【拒绝时报第一个模块的名字】—— 标题只是标题;真正的说明在 moduleDenied 那两句。
 */
export async function requireAnyModule(mods: ModuleEntry[]) {
    for (const m of mods) {
        if (await canEnterModule(m.permission)) return null
    }
    return refusal(mods[0].navKey, 'common.moduleDenied', 'common.moduleDeniedHint')
}

/**
 * 【模块之外,还有数据类】
 *     const denied = await requireDataClass('data.view_prices', 'margin.title')
 *     if (denied) return denied
 *
 * 模块回答"你进得来这一片吗",数据类回答"你看得见这一类数字吗"(perm2b 的
 * data.view_prices / data.view_pay / data.view_identity)。两者【互相不蕴含】。
 *
 * 【为什么必须单独把关,而不是等视图返回空】OPS-20 实测:live 的 operations 持
 * module.processing.view 却【没有】data.view_prices,于是它过得了模块守卫、从
 * batch_margin 读到零行,屏幕上是一张【空表】—— "没有可算毛利的批次"与"你看不见
 * 价格"长得一模一样。这正是 moduleGuard 抬头那条病,换到了数据类这一层。
 */
export async function requireDataClass(permission: string, titleKey: string) {
    if (await canEnterModule(permission)) return null
    return refusal(titleKey, 'common.dataClassDenied', 'common.dataClassDeniedHint')
}

/**
 * 【读的那一半之外,还有写的那一半】
 *     const denied = await requireEditPermission('module.pricing.edit', 'nav.metalPrices')
 *     if (denied) return denied
 *
 * requireModule 问的是"你进得来这个模块吗",对应基表的 SELECT 策略。本函数问的是
 * "你改得动这张表吗",对应它的 INSERT / UPDATE / DELETE 策略 —— 【同一条规矩的另一半】:
 * 守卫跟着数据自己的 RLS 走,而一张表的 RLS 本来就有读、写两个答案,它们可以不一样。
 *
 * 【措辞必须与模块拒绝不同】。走到这里的人往往【看得见】这份数据(读策略放行),
 * 只是存不下 —— 对他说"你没有这个模块的权限"是假的。所以另有一套 common.editDenied。
 *
 * 【这不是安全边界】,与 requireModule 同理:边界是那几条 WITH CHECK 策略。这里只是
 * 不要把一张注定被数据库拒收的表单摆到人面前(AGENTS.md §"永远不要为服务端必然拒绝
 * 的动作渲染提交控件")。
 */
export async function requireEditPermission(permission: string, titleKey: string) {
    if (await canEnterModule(permission)) return null
    return refusal(titleKey, 'common.editDenied', 'common.editDeniedHint')
}
