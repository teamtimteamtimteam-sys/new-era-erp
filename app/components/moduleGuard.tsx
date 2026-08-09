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

/**
 * 用法(每个受模块管辖的页面的第一行):
 *     const denied = await requireModule(MOD.finance)
 *     if (denied) return denied
 * 放在【任何查询之前】—— 拒绝要来自权限判断,不能是从空结果倒推出来的。
 */
export async function requireModule(mod: ModuleEntry) {
    if (await canEnterModule(mod.permission)) return null

    const t = await getTranslations()
    return (
        <div className="p-8 max-w-2xl">
            <h1 className="text-2xl font-bold mb-4">{t(mod.navKey)}</h1>
            <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded">
                <p className="font-medium">{t('common.moduleDenied')}</p>
                <p className="text-sm mt-1">{t('common.moduleDeniedHint')}</p>
            </div>
            <Link href="/" className="inline-block mt-4 text-sm text-blue-600 hover:underline">
                {t('common.backHome')}
            </Link>
        </div>
    )
}
