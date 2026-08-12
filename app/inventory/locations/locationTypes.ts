// LOC-1:库位在【应用这一侧】的形状。
//
// 【本文件保持纯 —— 不 import 任何服务端模块】客户端组件要用这里的类型;
// 取数与写入住在 page.tsx / actions.ts。混在一起会让构建以
// "You're importing a module that depends on next/headers" 失败(METAL-2 的教训,
// wasteClassOptions.ts 上写着同一条)。

export type LocationRow = {
    id: string
    code: string
    name: string
    zone: string | null
    is_active: boolean
    /** 已配置的分类 code;空数组 = 未配置 —— 见下。 */
    allowed_codes: string[]
}

// ═══════════════════════════════════════════════════════════════════════════
// 【空数组不是"不允许任何分类",是"还没有人决定"】
//
// 这是本刀最容易被下一个人读错的一件事,所以它是一个具名函数而不是一处
// `.length === 0` 的判断:让"未配置"在代码里有个名字,读的人就不会顺手把它
// 当成一个空集合去做集合运算。
//
// 数据库那一侧的同一句话写在 storage_location_allowed_classes 的表注释里:
// 零行 = 未配置 = 将来的检查【告警,绝不拒绝】;而"配了、但不含这一类"是
// 一个有人做过的决定,那才该拒。把两者压成同一个布尔量,就是把【没人想过】
// 演成【想过、结论是不行】。
// ═══════════════════════════════════════════════════════════════════════════
export function isUnconfigured(row: { allowed_codes: string[] }): boolean {
    return row.allowed_codes.length === 0
}
