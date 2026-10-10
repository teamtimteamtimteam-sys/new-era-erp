// MES-6a-2(2026-10-10,MES-6a Step 0 Q3 · Q4,Tim):表单里的指标格 → record_assay_result 的 p_indicators。
//   空格整格忽略(空 = 这一份没报);读不懂的数或负数按名拒(与库里的 INDICATOR_VALUE_INVALID 同一句,先在这里说一遍)。
//   没有上限 —— 一个限是一条标准,而 Q3 说没有(V17 在 MES-6b)。
//   值【按敲进去的那串字交出去】(库里 ::numeric 原样收)—— 不经 JS 的浮点,11.40 就是 11.40。
export const INDICATOR_FIELD_PREFIX = 'indicator:'

export function indicatorsPayload(formData: FormData):
    | { ok: true; value: { indicator: string; value: string }[] }
    | { ok: false; indicator: string; raw: string } {
    const out: { indicator: string; value: string }[] = []
    for (const [key, v] of formData.entries()) {
        if (!key.startsWith(INDICATOR_FIELD_PREFIX)) continue
        const indicator = key.slice(INDICATOR_FIELD_PREFIX.length)
        const raw = String(v ?? '').trim()
        if (raw === '') continue
        const n = Number(raw)
        if (!Number.isFinite(n) || n < 0) return { ok: false, indicator, raw }   // = INDICATOR_VALUE_INVALID
        out.push({ indicator, value: raw })
    }
    return { ok: true, value: out }
}
