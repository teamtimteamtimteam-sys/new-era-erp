import { getTranslations } from '@/lib/i18n/server'

// app/logistics/logisticsErrorCodes.ts
// LOG-1c:物流模块的具名拒绝 → 人话。端口自 taskErrorCodes.ts。
//
// 【为什么它必须存在】LOG-1a 把三条规矩装在触发器上(重叠报价、货代不能当采购单
// 供应商、供货商不能挂物流属性)。触发器抛的是 CODE|参数 —— 那串东西对操作员
// 是天书。界面同时不提供做不到的手势,两层缺一不可。
const LOGISTICS_ERROR_CODES = new Set([
    'FORWARDER_RATE_QUOTE_OVERLAP',
    'RATE_QUOTE_VENDOR_NOT_A_FORWARDER',
    'FORWARDER_DETAILS_NOT_A_FORWARDER',
    'PO_VENDOR_IS_A_FORWARDER',
    // LOG-2b:集装箱层的具名拒绝
    'CONTAINER_FORWARDER_NOT_A_FORWARDER',
    'SHIPMENT_IMMUTABLE',
    'CONTAINER_DOC_NA_REASON_REQUIRED',
    'DETACH_REASON_REQUIRED',
    'CONTAINER_NOT_FOUND',
    'SHIPMENT_NOT_FOUND',
    'SHIPMENT_NOT_IN_A_CONTAINER',
    'DELETE_REASON_REQUIRED',
    'CONTAINER_MILESTONE_IMMUTABLE',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeLogisticsError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const t = await getTranslations()

    const match = raw.match(CODE_RE)
    if (match && match[1] === 'PERMISSION_DENIED') return t('common.restricted')
    if (!match || !LOGISTICS_ERROR_CODES.has(match[1])) {
        // 【不在集合里的原样返回】—— 编一句人话去盖一个没见过的错误,
        // 会让下一个人以为系统认得它。
        return raw
    }
    const params: Record<string, string> = {}
    if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return t('logistics.opErrors.' + match[1], params)
}
