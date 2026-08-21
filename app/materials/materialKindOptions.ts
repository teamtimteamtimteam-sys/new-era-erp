// PROC-1:物料【种类】在应用这一侧的形状。
//
// 【本文件保持纯 —— 不 import 任何服务端模块】客户端组件要用这里的类型与哨兵值;
// 取数那一半住在 materialKindQuery.ts。混在一起会让构建以
// "You're importing a module that depends on next/headers" 失败
// (METAL-2 的教训,wasteClassOptions.ts 抬头也记着同一条)。
export type MaterialKind = {
    code: string
    name_en: string
    name_zh: string
    may_ever_be_processed: boolean
}

// 表单里代表【还没选】的取值。
//
// 【为什么要一个哨兵,而不是空串】空串在 FormData 里与"这个字段根本没提交"
// 无法区分。而这两列【必须是明说出来的选择】—— 一个悄悄成立的默认值,
// 就是一个没人做过的决定从表单进来,而不是从 NULL 进来。
export const KIND_UNCHOSEN = '__unchosen__'

// 【可不可以投料:三态解析,而"没选"是其中一态】
// 表单用两个都不预选的单选钮表达"还没选" —— 提交上来就是 null,服务端按名拒。
export function parseProcessableField(raw: FormDataEntryValue | null): boolean | null {
    const v = String(raw ?? '').trim()
    if (v === 'yes') return true
    if (v === 'no') return false
    return null
}
