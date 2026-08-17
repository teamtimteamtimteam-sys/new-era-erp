import { getTranslations } from '@/lib/i18n/server'

// app/materials/materialPolicyErrorCodes.ts
// ASY-P1 的写入口 set_material_required_metals() 抛出的错误码。
// 端口自 assayErrorCodes.ts。不在集合内的是真正未编码的 DB 错误,原样返回 ——
// 一个被翻译器吞掉的陌生错误,比一串机器码更坏(docs/machine-text-reaching-humans.md)。
const MATERIAL_POLICY_ERROR_CODES = new Set([
    'MATERIAL_REQUIRED',
    'MATERIAL_NOT_FOUND',
    'METAL_UNKNOWN',
    'METAL_DUPLICATED',
])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..."
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeMaterialPolicyError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    // 权限拒绝走 require_permission,它抛的是 PERMISSION_DENIED —— 那不是错误,
    // 是这个人不该改这件事。与化验那一份同一条处置。
    if (match && match[1] === 'PERMISSION_DENIED') {
        return (await getTranslations())('common.restricted')
    }

    if (!match || !MATERIAL_POLICY_ERROR_CODES.has(match[1])) {
        return raw
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v
        })
    }

    return (await getTranslations())('materials.assayPolicy.errors.' + code, params)
}
