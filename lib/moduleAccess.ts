// lib/moduleAccess.ts
// 模块可见性的【服务端】一侧:谁能进哪个模块。清单与谓词求值器都在 lib/modules.ts
// (纯数据 + 纯函数,客户端也 import 得到);这里只负责【取权限码】,因为取码要读库。
//
// 【求值不在这里】判断一律走 lib/modules.ts 的 allows() —— 本文件不自己比对权限码。
// 这是 NAV-REG-1 的硬规矩:一条规则一个实现。
//
// getMyPermissions() 已经是 React cache() —— 同一次请求里导航条、首页、页面守卫
// 各调各的,数据库只打一次。
import {
    MODULES,
    allows,
    functionsForModule,
    type ModuleEntry,
    type FunctionEntry,
    type PermissionSpec,
} from '@/lib/modules'
import { getMyPermissions } from '@/lib/permissions'

/** 导航条要渲染的一项:模块本身 + 【这个人进不进得去】。 */
export type ModuleAccess = { module: ModuleEntry; allowed: boolean }

/**
 * 【NAV-REG-1 / R4:这里从"过滤"变成了"标记"】。
 *
 * 从前这个函数叫 getVisibleModules,返回【进得去的那些】—— 于是一个进不去的模块
 * 在导航条上【整个消失】,而屏幕上"这个模块不存在"与"你不能进"长得一模一样。
 * 那正是 moduleGuard 抬头那条病(进不去的空 ≠ 真的空)在导航层的样子。
 *
 * Tim 的裁定 D5:【一个进不去的模块要显示成一条具名的限制,而不是一处缺席】。
 * 所以本函数现在返回【全部】模块,每个带一个 allowed;藏不藏由渲染层决定,而
 * 渲染层的答案是"不藏,写上「受限」"(app/components/NavLinks.tsx)。
 *
 * 【下一个读到这里的人:不要把过滤加回来】。返回全部不是遗漏,是这一刀的内容本身。
 */
export async function getModuleAccess(): Promise<ModuleAccess[]> {
    const perms = await getMyPermissions()
    return MODULES.map((m) => ({ module: m, allowed: allows(m.permission, perms) }))
}

/**
 * 单个谓词的判断。页面守卫与 TopNav 用它,拿到的是【权限答复】而不是"查出来是空的"。
 * 接受单码(绝大多数场合)或谓词 —— 两者都交给同一个 allows()。
 */
export async function canEnter(spec: PermissionSpec): Promise<boolean> {
    return allows(spec, await getMyPermissions())
}

/** 某个模块名下的功能 + 【这个人进不进得去】。 */
export type FunctionAccess = { fn: FunctionEntry; allowed: boolean }

/**
 * 【一个功能在它每个属主模块下各出现一次 —— 那正是 NAV-REG-1 的全部内容】。
 *
 * 属主模块的界面调它来画自己名下的功能入口:入口的地址、标签与判据【全部来自
 * 注册表】,而页面守卫(requireFunction)读的是同一条注册表条目。于是
 * "谁看得见这个入口"与"谁进得去这一页"是同一个表达式,不可能各错一次 ——
 * 手写一个 <Link> 就没有任何东西保证这件事,那是 OPS-15 要杀掉的那种漂移。
 */
export async function getFunctionAccess(moduleHref: string): Promise<FunctionAccess[]> {
    const perms = await getMyPermissions()
    return functionsForModule(moduleHref).map((fn) => ({ fn, allowed: allows(fn.permission, perms) }))
}
