// METAL-2:行情指数的选项来源。
//
// 【从表里现读,不写死】加一个指数(Fastmarkets、Asian Metal)是往
// metal_price_indices 里加一行,不是改这个文件 —— 与 certificate_types 同一条。
// 所以这里没有 LME/SMM 的字面量。
//
// 【未声明指数是一个可选项,不是留空的默认】表单里它是一个【要选的】选项,
// 写着"未声明指数(与既有序列一致)"。理由:既有 11 行都在那条未标注的序列上,
// 而尚未声明指数的公式只看得见它 —— 在公式被标注之前,操作员必须还能往那条序列
// 里录价,否则今天的计价会安静地停在最后一条老报价上(那正是 ASY-3 记的陈旧问题)。
// 让它成为一个【明写的选择】而不是"不选就是它",是这两者之间唯一诚实的位置。
export type MetalPriceIndex = {
    code: string
    name_en: string
    name_zh: string
    quote_currency: string | null
}

// 表单里代表"未声明指数"的取值。空串在 FormData 里与"没填"无法区分,
// 所以用一个明确的哨兵值,由服务端翻译成 NULL。
export const INDEX_UNSTATED = '__unstated__'


// 【本文件不 import 任何服务端模块】IndexPicker 是客户端组件,它要用这里的类型与
// 哨兵值;取数据的那一半住在 indexQuery.ts(服务端)。混在一起会让构建当场失败 ——
// 而那正是它上一版的下场,值得留一句话在这里。
//
// 表单值 → 存进数据库的值。哨兵与空串都是【未声明】(NULL)。
export function parseIndexField(raw: FormDataEntryValue | null): string | null {
    const v = String(raw ?? '').trim()
    return v === '' || v === INDEX_UNSTATED ? null : v
}
