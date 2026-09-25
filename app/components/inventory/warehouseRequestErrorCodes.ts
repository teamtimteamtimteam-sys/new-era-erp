import { getTranslations } from '@/lib/i18n/server'
import { localizeDeletionError } from '@/app/components/inventory/deletionErrorCodes'
import { isStockErrorCode, localizeStockError } from '@/app/components/inventory/stockErrorCodes'
import { localizeProcessingError } from '@/app/operation/errorCodes'
import { localizeCodError } from '@/app/inbound/codErrorCodes'
import { localizeFinanceError } from '@/app/finance/financeErrorCodes'

// app/components/inventory/warehouseRequestErrorCodes.ts
// ★ APR-7(Tim 2026-09-25):注销批次、加工回滚、作废销毁证书 —— 仓库提,CFO 批。这是那四扇提交的门、
//   decide / withdraw 与三扇旧门(按名拒 WAREHOUSE_NEEDS_APPROVED_REQUEST)共用的一份拒绝词表。
//   【只收这一刀新造的码】—— 批准那一刻按原话冒出来的旧码(欠款、订单预留、产出动过、证书、台账、
//   审批四眼)仍由它们各自那一份说,这里按码族转交,不抄第二份译文。
const WAREHOUSE_REQUEST_ERROR_CODES = new Set([
    'WAREHOUSE_NEEDS_APPROVED_REQUEST',
    'WAREHOUSE_REQUEST_OPEN',
    'WAREHOUSE_REQUEST_FREEZES_BATCH',
    'WAREHOUSE_REQUEST_NOT_NEEDED',
    'WAREHOUSE_REQUEST_NO_OTHER_DECIDER',
    'WAREHOUSE_REQUEST_REASON_REQUIRED',
    'WAREHOUSE_REQUEST_REJECT_REASON_REQUIRED',
    'WAREHOUSE_REQUEST_NOT_FOUND',
    'WAREHOUSE_REQUEST_NOT_SUBMITTED',
    'WAREHOUSE_REQUEST_NOT_OPEN',
    'WAREHOUSE_REQUEST_KIND_UNKNOWN',
])

// 审批四眼那一族(forbid_self_approval · require_approver_for · 开关)归财务那一份
const APPROVAL_FAMILY = /^(SELF_APPROVAL_FORBIDDEN|APPROVAL_NOT_AUTHORISED|APPROVALS_NOT_ENABLED)$/
// 加工那一族(回滚的原话)
const PROCESSING_FAMILY = /^(OUTPUT_CONSUMED|RUN_NOT_FOUND|RUN_ALREADY_DELETED|ROLLBACK_REASON_REQUIRED|IOD_RESTORE_MISMATCH)$/

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeWarehouseRequestError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    if (match && match[1] === 'PERMISSION_DENIED') {
        return (await getTranslations())('common.restricted')
    }
    if (match && WAREHOUSE_REQUEST_ERROR_CODES.has(match[1])) {
        const params: Record<string, string> = {}
        if (match[2]) {
            match[2].split('|').forEach((v, i) => {
                params[String(i)] = v
            })
        }
        return (await getTranslations())('warehouseRequest.errors.' + match[1], params)
    }
    const code = match?.[1] ?? ''
    if (APPROVAL_FAMILY.test(code)) return await localizeFinanceError(raw)
    if (PROCESSING_FAMILY.test(code)) return await localizeProcessingError(raw)
    if (code.startsWith('COD_') || code === 'REASON_REQUIRED') return await localizeCodError(raw)
    if (isStockErrorCode(raw)) return await localizeStockError(raw)
    // 其余(欠款、订单预留、定价申请、软删守卫……)与共用兜底:注销那一份
    return await localizeDeletionError(raw)
}
