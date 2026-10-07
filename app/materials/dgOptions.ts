// MES-3b(2026-10-07,MES-0 Q38 · Q39;MES-3b Step 0 Q12 · Q17,Tim):危险品 UN 编号与 HS 编码的类型与表单字段解析 ——
//   不是 'use client' 文件,所以服务端动作与客户端控件都能从这里取(与 neaCategoryOptions.ts 同一个理由)。
export type DgCode = { code: string; name_en: string; name_zh: string; dg_class: string }
export const DG_NOT_SET = ''

/** 空 = 没人选过(V35:标签与发货单上提示"没给",不拒)。 */
export function parseDgField(raw: FormDataEntryValue | null): string | null {
    const v = String(raw ?? '').trim()
    return v === DG_NOT_SET ? null : v
}

/** HS 编码:空 = 没给(V31)。形状(6–12 位数字,可带点)由表上的 materials_hs_code_shape 判 —— 这里不抄第二份判据,只去掉两头空白。 */
export function parseHsField(raw: FormDataEntryValue | null): string | null {
    const v = String(raw ?? '').trim()
    return v === '' ? null : v
}
