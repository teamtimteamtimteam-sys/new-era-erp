import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'

// 库位相关的数据库错误码。端口自 app/inbound/assayErrorCodes.ts。
// 不在集合内的是真正未编码的数据库错误,【交给共用兜底 lib/machine-text.ts】——
// ★ 兜底【把那个码留在句子里】,所以它不是「一句编出来的中文」:
//   它既没有假装系统理解了刚才发生的事,也没有把 SQL 原文摔到人脸上。
//   (BUGFIX-1b:原先这里写的是「一句看不懂的英文比一句编出来的中文强」——
//    那句话在只有这两个选项时是对的,而现在有第三个。)
const LOCATION_ERROR_CODES = new Set([
    // 重号:UNIQUE 给保证,触发器给名字(db/tables/storage_locations.sql 有账)
    'LOC_CODE_EXISTS',
    // 硬删:这张表没有删除路径,下架只有停用
    'LOCATION_NO_HARD_DELETE',
])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..."(同 localizeAssayError)。
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeLocationError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    if (match && match[1] === 'PERMISSION_DENIED') {
        return (await getTranslations())('common.restricted')
    }

    if (!match || !LOCATION_ERROR_CODES.has(match[1])) {
        return await fallbackForRawError(raw, 'localizeLocationError@app/inventory/locations/locationErrorCodes.ts')
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v
        })
    }

    return (await getTranslations())('locations.errors.' + code, params)
}
