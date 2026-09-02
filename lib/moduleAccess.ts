// lib/moduleAccess.ts
// 模块可见性的【服务端】一侧。清单与谓词求值器都在 lib/modules.ts(纯数据 + 纯函数,
// 客户端也 import 得到);这里只负责【取权限码】,因为取码要读库。
//
// 【求值不在这里】判断一律走 lib/modules.ts 的 allows() —— 本文件不自己比对权限码。
// 这是 NAV-REG-1 的硬规矩:一条规则一个实现。
//
// getMyPermissions() 已经是 React cache() —— 同一次请求里顶栏、首页、页面守卫
// 各调各的,数据库只打一次。
import {
    MODULES,
    MODULE_GROUPS,
    allows,
    functionsForModule,
    type ModuleEntry,
    type FunctionEntry,
    type PermissionSpec,
} from '@/lib/modules'
import { getMyPermissions } from '@/lib/permissions'

/** 一个二级条目 + 【这个人进不进得去】。 */
export type FunctionAccess = { fn: FunctionEntry; allowed: boolean }

/** 顶栏要渲染的一个一级模块:模块 + 可进性 + 它名下的二级条目(各带可进性)。 */
export type ModuleAccess = {
    module: ModuleEntry
    allowed: boolean
    entries: FunctionAccess[]
    /** 只有财务非空:第三级分组,顺序即 FINANCE_GROUPS 的顺序。 */
    groups: { key: string; entries: FunctionAccess[] }[]
}

/**
 * 【NAV-REG-1 / R4:这里是"标记",不是"过滤"】。
 *
 * 从前它叫 getVisibleModules,返回【进得去的那些】—— 于是一个进不去的模块在导航条上
 * 【整个消失】,而屏幕上"这个模块不存在"与"你不能进"长得一模一样。那正是 moduleGuard
 * 抬头那条病(进不去的空 ≠ 真的空)在导航层的样子。
 *
 * Tim 的裁定 D5:【一个进不去的模块要显示成一条具名的限制,而不是一处缺席】。
 * 所以本函数返回【全部】模块,每个带一个 allowed。
 * **下一个读到这里的人:不要把过滤加回来。返回全部不是遗漏,是这一刀的内容本身。**
 *
 * ★ IA-BUILD-1:allowed 是【推导】的,不是读一个字段 ★
 * 一个一级模块进不进得去 = 它名下【有没有任何一条二级条目进得去】。
 * 理由与 M6 的自动成立见 lib/modules.ts 抬头 §二。二级条目各自的 allowed
 * 同时算出来一起返回 —— 顶栏要画的就是这两层,一次查询、一份判据。
 */
export async function getModuleAccess(): Promise<ModuleAccess[]> {
    const perms = await getMyPermissions()
    return MODULES.map((m) => {
        const entries = functionsForModule(m.id).map((fn) => ({
            fn,
            allowed: allows(fn.permission, perms),
        }))
        // ★【第三级【只有财务有】—— Tim 的 D1,而这一行必须写死那个判断】★
        //
        // 【为什么:一个实测出来的缺陷】此前这里对【每一个】模块都算分组,于是
        // 任何一个模块只要名下有【一条】带 group 的跨属主条目,它就被当成"有第三级",
        // 而渲染层走分组分支 —— **它自己那些没有 group 的条目就整批不见了**。
        // 实测(本地探针,admin):
        //     物流 只画出 1 条(运费),货代/航线/货柜【三条全没了】;
        //     库存 只画出 1 条(报表),现况/库位/盘点/物料/收货/产出【六条全没了】;
        //     运营 只画出 1 条(毛利),四条加工条目全没了。
        // 这正是本刀反复在讲的那个形状:**一处缺席,而没有任何东西说出来。**
        // group 字段的意思是"它在【财务】的第三级里归哪一组",不是"它自带一个层级"——
        // /finance/freight 同属物流与财务,在财务底下归「应付」,在物流底下就是一条。
        // TOOLS-1 ①b:从【一个写死的财务 id】换成【一张表】。上面那段警告一字不改地
        // 继续成立 —— 一个模块只要名下有一条带 group 的条目就会走分组分支,
        // 所以"哪个模块有第三级"必须由这张表说了算,而不是由条目自己带出来。
        const groupKeys = MODULE_GROUPS[m.id]
        const groups =
            !groupKeys
                ? []
                : groupKeys.map((key) => ({
                      key: key as string,
                      entries: entries.filter((e) => e.fn.group === key),
                  }))
                      // **空组不渲染** —— 一个组名下面一条都没有,那不是"受限",
                      // 那是这个人一条都进不去,而每一条自己会说「受限」。
                      .filter((g) => g.entries.length > 0)
        return {
            module: m,
            allowed: entries.some((e) => e.allowed),
            entries,
            groups,
        }
    })
}

/**
 * 单个谓词的判断。页面守卫与顶栏用它,拿到的是【权限答复】而不是"查出来是空的"。
 * 接受单码(绝大多数场合)或谓词 —— 两者都交给同一个 allows()。
 */
export async function canEnter(spec: PermissionSpec): Promise<boolean> {
    return allows(spec, await getMyPermissions())
}

/**
 * 【一个功能在它每个属主模块下各出现一次 —— 那正是 NAV-REG-1 的全部内容】。
 *
 * 属主模块的界面调它来画自己名下的条目:地址、标签与判据【全部来自注册表】,
 * 而页面守卫(requireFunction)读的是同一条注册表条目。于是"谁看得见这个入口"
 * 与"谁进得去这一页"是同一个表达式,不可能各错一次。
 */
export async function getFunctionAccess(moduleId: string): Promise<FunctionAccess[]> {
    const perms = await getMyPermissions()
    return functionsForModule(moduleId).map((fn) => ({ fn, allowed: allows(fn.permission, perms) }))
}
