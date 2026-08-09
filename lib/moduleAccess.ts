// lib/moduleAccess.ts
// 模块可见性的【服务端】一侧:谁能进哪个模块。清单本身在 lib/modules.ts(纯数据,
// 客户端也 import 得到);这里只做过滤,因为过滤要读权限。
//
// getMyPermissions() 已经是 React cache() —— 同一次请求里导航条、首页、页面守卫
// 各调各的,数据库只打一次。
import { MODULES, type ModuleEntry } from '@/lib/modules'
import { getMyPermissions } from '@/lib/permissions'

/** 当前登录者能进的模块,保持 MODULES 的顺序。 */
export async function getVisibleModules(): Promise<ModuleEntry[]> {
    const perms = await getMyPermissions()
    return MODULES.filter((m) => perms.includes(m.permission))
}

/** 单个模块的判断。页面守卫用它,拿到的是【权限答复】而不是"查出来是空的"。 */
export async function canEnterModule(permission: string): Promise<boolean> {
    return (await getMyPermissions()).includes(permission)
}
