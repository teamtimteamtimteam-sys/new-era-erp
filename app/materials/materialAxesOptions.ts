// PROC-2b:三条物料级状态轴在应用这一侧的形状。
//
// 【本文件保持纯 —— 不 import 任何服务端模块】客户端组件要用这里的类型与哨兵值;
// 取数那一半住在 materialAxesQuery.ts(与 wasteClassOptions / materialKindOptions
// 同一条,理由是 METAL-2 那次 "importing a module that depends on next/headers")。
export type MaterialForm = {
    code: string; name_en: string; name_zh: string
    // 【适用条件之一】这个形态要不要拆解 —— 规格尺寸那条轴只在它为真时成立。
    implies_dismantling: boolean
    // PROC-BUILD-1(R5):法律上允许不允许卖这个形态。**屏幕上只用来【说出来】** ——
    // 拦是数据库那四个触发器的事,这里不拦。一个只在屏幕上拦的规则,
    // 换一条路进来就绕过去了。
    may_be_sold: boolean
}
export type MaterialSource = {
    code: string; name_en: string; name_zh: string
    // 这一来源的料从来没充过电 —— PROC-3 的闸要读它。屏幕上只用来解释。
    implies_never_charged: boolean
}
export type MaterialSizeFormat = { code: string; name_en: string; name_zh: string }

// 表单里代表【还没选】的取值。与 KIND_UNCHOSEN 同一条:
// 空串在 FormData 里与"这个字段根本没提交"分不开,而这几列必须是明说出来的选择。
export const AXIS_UNCHOSEN = '__unchosen__'

export function parseAxisField(raw: FormDataEntryValue | null): string | null {
    const v = String(raw ?? '').trim()
    return v === '' || v === AXIS_UNCHOSEN ? null : v
}
