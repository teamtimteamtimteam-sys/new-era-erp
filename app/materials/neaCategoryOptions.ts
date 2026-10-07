// MES-3a(2026-10-06,MES-3a Step 0 Q4):NEA 废物类别的类型与表单字段解析 —— 不是 'use client' 文件,
//   所以服务端动作与客户端控件都能从这里取(从一个 'use client' 模块里导入函数,到了服务端就是一个调不了的客户端引用)。
export type NeaCategory = { code: string; name_en: string; name_zh: string }
export const NEA_CATEGORY_NOT_SET = ''

/** 空 = 没人分过(收货照收,记 category_not_set)。 */
export function parseNeaCategoryField(raw: FormDataEntryValue | null): string | null {
    const v = String(raw ?? '').trim()
    return v === NEA_CATEGORY_NOT_SET ? null : v
}
