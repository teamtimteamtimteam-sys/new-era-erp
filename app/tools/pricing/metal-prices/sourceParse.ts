// app/tools/pricing/metal-prices/sourceParse.ts
// LME-1b:把 SourcePicker 的三个字段翻成库要的形状。两张录入表单共用一份 ——
// 抄两遍就是第二份会漂开的解析。
//
// 【空凭据必须落成 NULL,不是空串】1a 的 fixture 91B 钉住这一条:
// 空串会让"没记录过凭据"看起来像"记过一个空的"。
import { DELAY_DELAYED, DELAY_SAME_DAY } from './sourceOptions'

export function parseSourceFields(formData: FormData): {
    source: string
    sourceReference: string | null
    quoteDelayed: boolean | null
} {
    const source = String(formData.get('quote_source') ?? '').trim()
    const ref = String(formData.get('source_reference') ?? '').trim()
    const delay = String(formData.get('quote_delayed') ?? '').trim()
    return {
        source,
        sourceReference: ref === '' ? null : ref,
        // 【三态】未记录 → null。哨兵之外的任何值都读成 null,不猜。
        quoteDelayed: delay === DELAY_DELAYED ? true : delay === DELAY_SAME_DAY ? false : null,
    }
}
