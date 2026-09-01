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
import { canEnter } from '@/lib/moduleAccess'
import { getTranslations } from '@/lib/i18n/server'
import type { ModuleEntry, FunctionEntry } from '@/lib/modules'

/** 两种拒绝共用的那一块屏 —— 措辞不同,形状必须相同。 */
async function refusal(titleKey: string, deniedKey: string, hintKey: string) {
    const t = await getTranslations()
    return (
        // data-access-denied:给按角色的可达性检查用的【机器标记】。
        // 靠认文案字符串去分辨"拒绝页"漏过一次就是一次误报(REACH-1 首跑
        // 把 /settings/permissions 误当成"打得开"),所以标记跟着组件走。
        <div className="p-8 max-w-2xl" data-access-denied="1">
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
    if (await canEnter(mod.permission)) return null
    return refusal(mod.navKey, 'common.moduleDenied', 'common.moduleDeniedHint')
}

/**
 * 【有些页面属于几个模块,不是一个】—— NAV-REG-1
 *     const denied = await requireFunction(FN.margin)
 *     if (denied) return denied
 *
 * requireModule 问的是【那一个】模块;本函数问【这个功能的那一份判据】,而那份判据
 * 住在 lib/modules.ts 的 FUNCTIONS 里,与渲染入口用的是【同一个表达式】。
 *
 * 【哪一份是权威的:注册表】。页面守卫不自己写判据,它把注册表条目【整个】接过来
 * (requireFunction(FN.margin)),于是"谁看得见这个入口"与"谁进得去这一页"不可能
 * 各错一次 —— 这是 Tim 的 3d:两者不得是两份定义。页面这一侧靠【不表达】来服从。
 *
 * 【两句拒绝,一个谓词】谓词的两半各自对应一句话:
 *   any 那一半(模块)不满足   → 你没有进入该模块的权限
 *   all 那一半(数据类)不满足 → 这个数字属于价格信息
 * 迁移前 /margin 上是 requireAnyModule 后接 requireDataClass 两次调用,顺序与措辞
 * 与这里【逐字相同】;区别只是判据不再写在页面里。
 *
 * 【requireDataClass 去哪了】它此前只有一个调用者,就是 /margin ——
 * 而 /margin 的两道守卫正是本函数取代的那两道。于是本刀之后它【零调用者】,
 * 所以删掉。它表达的那个区别(模块拒绝 ≠ 数据类拒绝)一个字都没有丢:
 * 它就在下面那两句 refusal 里,由谓词的两半决定用哪一句。
 * 【为什么不留着"以后可能有人要用"】这一刀刚刚因为同一条理由删掉了
 * moduleForPath 与 alsoCovers —— 一个没有调用者的导出,是下一个人据以断定
 * "这里已经接好了"的东西。要用的时候再加回来,那是一行的事。
 *
 * 【标题报功能自己的名字】。从前 requireAnyModule 报的是"第一个模块"的名字 ——
 * 那是它没有更好东西可报时的将就(它的旧注释自己写着"标题只是标题")。
 * 一个功能现在有自己的身份,所以它报自己的名字。
 */
export async function requireFunction(fn: FunctionEntry) {
    const spec = fn.permission
    if (await canEnter(spec)) return null
    if (typeof spec === 'string') {
        const isDataClass = spec.startsWith('data.')
        return refusal(
            fn.navKey,
            isDataClass ? 'common.dataClassDenied' : 'common.moduleDenied',
            isDataClass ? 'common.dataClassDeniedHint' : 'common.moduleDeniedHint',
        )
    }
    // 模块那一半先答 —— 缺模块是更根本的一次缺席(与迁移前的调用顺序同序)。
    const moduleHalfOk = spec.any === undefined || (await canEnter({ all: [], any: spec.any }))
    if (!moduleHalfOk) return refusal(fn.navKey, 'common.moduleDenied', 'common.moduleDeniedHint')
    // 走到这里是 all 那一半没过。【措辞看它是哪一类码】,不假定它一定是数据类:
    // 今天 FUNCTIONS 里 all 那一半确实只有 data.*,但把这个巧合写成假设,
    // 下一条 all 里放模块码的功能就会对着人说"这个数字属于价格信息"。
    const allIsDataClass = spec.all.length > 0 && spec.all.every((c) => c.startsWith('data.'))
    return allIsDataClass
        ? refusal(fn.navKey, 'common.dataClassDenied', 'common.dataClassDeniedHint')
        : refusal(fn.navKey, 'common.moduleDenied', 'common.moduleDeniedHint')
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
    if (await canEnter(permission)) return null
    return refusal(titleKey, 'common.editDenied', 'common.editDeniedHint')
}
