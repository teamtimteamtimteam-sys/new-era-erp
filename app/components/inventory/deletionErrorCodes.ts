import { getTranslations } from '@/lib/i18n/server'

// app/components/inventory/deletionErrorCodes.ts
// AUDEL-1b:软删那扇门(soft_delete_inbound_batch / soft_delete_output_batch)
// 与守卫 guard_soft_delete_provenance 抛出的错误码。端口自 assayErrorCodes.ts。
// 【进料与产出共用一份】两边的门是同一个形状,分成两份只会各自漂开。
const DELETION_ERROR_CODES = new Set([
    'DELETE_REASON_REQUIRED',
    'SOFT_DELETE_NO_DIRECT_UPDATE',
    'INBOUND_NOT_FOUND',
    'OUTPUT_NOT_FOUND',
    // AUDEL-1a 的三条硬删拒绝 —— 界面今天走不到它们(没有硬删路径),
    // 收在这里是为了万一有人从别处撞上时看到的是人话而不是机器码。
    'BATCH_NO_HARD_DELETE',
    'STOCKTAKE_NO_HARD_DELETE',
    'PO_NO_HARD_DELETE',
    // SO-2:一批还许着人的货不能就这么注销
    'SO_BATCH_HAS_RESERVATIONS',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeDeletionError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    if (match && match[1] === 'PERMISSION_DENIED') {
        return (await getTranslations())('common.restricted')
    }
    if (!match || !DELETION_ERROR_CODES.has(match[1])) {
        return raw
    }
    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v
        })
    }
    return (await getTranslations())('deletion.errors.' + code, params)
}
