// MAT-1:受控废物分类在【应用这一侧】的形状。
//
// 【本文件保持纯 —— 不 import 任何服务端模块】客户端组件要用这里的类型与哨兵值;
// 取数那一半住在 wasteClassQuery.ts。混在一起会让构建以
// "You're importing a module that depends on next/headers" 失败(METAL-2 的教训)。
export type WasteClass = {
    code: string
    name_en: string
    name_zh: string
    is_controlled: boolean
}

// 表单里代表【未分类】的取值。
//
// 【它是一个要选的选项,不是"留空就是它"】——「未分类」的意思是"没有人分过类",
// 而那与「分类为非受控」在合规判断上不是一回事。把它做成默认的空值,
// 等于让人在没有做出判断时看起来像做出了判断。空串在 FormData 里与"没填"
// 无法区分,所以用一个明确的哨兵值,由服务端翻译成 NULL。
export const WASTE_CLASS_UNCLASSIFIED = '__unclassified__'

export function parseWasteClassField(raw: FormDataEntryValue | null): string | null {
    const v = String(raw ?? '').trim()
    return v === '' || v === WASTE_CLASS_UNCLASSIFIED ? null : v
}
