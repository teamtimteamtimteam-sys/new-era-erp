import { getTranslations } from '@/lib/i18n/server'

// STK-1:库存状态(暂扣/释放)相关的数据库错误码。端口自 assayErrorCodes.ts。
// 不在集合内的是真正未编码的数据库错误,【原样返回】。
const STOCK_ERROR_CODES = new Set([
    'STK_HOLD_EXCEEDS_AVAILABLE',
    'STK_RELEASE_EXCEEDS_HELD',
    'STK_REASON_REQUIRED',
    'STK_QTY_INVALID',
    'STK_ONE_BATCH',
    // 桶不许为负 —— 正常路径撞不到它(hold/release 先按名拒绝了),
    // 但它是最后一道结构性守卫,撞上时必须说人话而不是抛一句触发器原文。
    'STK_NEGATIVE_BUCKET',
    // IOD-1:转移与排空
    'IOD_TRANSFER_EXCEEDS_BUCKET', 'IOD_TRANSFER_SAME_LOCATION', 'IOD_TRANSFER_TO_INACTIVE',
    'IOD_SALE_EXCEEDS_AVAILABLE', 'IOD_CONSUME_EXCEEDS_AVAILABLE',
    'IOD_DRAIN_INSUFFICIENT', 'IOD_RESTORE_MISMATCH',
    // IOD-1b:收货库位。【操作员真会撞上它】—— 表单开着的时候有人把那个库位
    // 停用了,提交就落到这里;不接成句子,他看到的是一串 IOD_RECEIPT_LOCATION_INACTIVE|SG-A1。
    'IOD_RECEIPT_LOCATION_INACTIVE', 'IOD_RECEIPT_LOCATION_UNKNOWN',
    // IOD-2:三态里【唯一会拒绝的那一态】—— 有人配了这个库位,并且没有把这一类
    // 放进去。另外两态是告警,不走这里(它们从返回值回来,见 localizeStockWarnings)。
    'IOD_CLASS_EXCLUDED',
    // IOD-2-fu1:三个建批次入口的日期【按名】必填。不按名,漏到界面上的是
    // FIN-32 那句 "violates check constraint inventory_movements_business_date_required"
    // —— 手走查出来的正是这一句。
    'ARRIVAL_DATE_REQUIRED', 'OUTPUT_DATE_REQUIRED',
    // SO-2:【一批还许着人的货注销不掉】。它由注销触发器抛出,所以撞上它的是
    // 产出批次页上按注销的那个人 —— 而他多半不知道"预留"是什么。消息里因此
    // 点名到底是哪几张订单在扣着它,并直接给出补救(先去那张单上释放)。
    // 【为什么归在库存这一族而不是销售那一族】撞上它的是库存/产出侧的动作,
    // 判据只能有一份(IOD-2-fu1 的教训),所以它跟着抛出它的那扇门走。
    'SO_BATCH_HAS_RESERVATIONS',
])

// IOD-2:【告警】的编码集合。与上面的拒绝分开,因为它们走的通道就不同 ——
// 拒绝从抛出的异常里来,告警从 RPC 的返回值里来(那一次调用是成功的)。
// 分成两个集合而不是一个,是为了让"把告警错当拒绝"这件事写不出来。
const STOCK_WARNING_CODES = new Set([
    'IOD_CLASS_UNCONFIGURED_LOCATION',
    'IOD_MATERIAL_UNCLASSIFIED',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

// IOD-2-fu1:【调用点问的是"这条错误归不归我管",而不是"它长得像不像某几个码"】
//
// 在此之前,三个 action 各自写着一句手抄的正则:
//     /IOD_RECEIPT_LOCATION_|IOD_CLASS_EXCLUDED/.test(error.message)
// 那是【第二份会漂开的清单】—— 每加一个库存错误码,都要记得去三处各补一次,
// 漏掉哪一处,那一处就把机器码原样端给操作员(IOD-1b 已经为这件事付过一次账,
// 当时漏的是三个 action 全部)。判据只能有一份:就是下面这个集合本身。
//
// 于是新增一个码只要动 STOCK_ERROR_CODES 一处,三个调用点自动跟上。
export function isStockErrorCode(message: string | null | undefined): boolean {
    const match = (message ?? '').trim().match(CODE_RE)
    return !!match && STOCK_ERROR_CODES.has(match[1])
}

export async function localizeStockError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    if (match && match[1] === 'PERMISSION_DENIED') {
        return (await getTranslations())('common.restricted')
    }
    if (!match || !STOCK_ERROR_CODES.has(match[1])) {
        return raw
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v
        })
    }
    return (await getTranslations())('stock.errors.' + code, params)
}

// IOD-2:把 RPC 返回值里的告警码接成句子。
//
// 【为什么必须有这一步,而且必须在 action 里被调用】IOD-1b 的教训是逐字的:
// IOD_RECEIPT_LOCATION_* 在数据库那一侧一直是对的,却因为没有人把它翻成人话,
// 操作员看到的是一串机器码。告警比拒绝更容易重蹈覆辙 —— 拒绝会挡住人,漏了
// 立刻有人喊;告警不挡任何人,漏了就是【无声地不存在】。
//
// 未编码的码【原样返回】而不是丢弃,与错误那一侧同一条:看得见才修得掉。
// IOD-2:三个建批次 RPC 成功之后都【重定向】走,而告警必须活过那一次重定向 ——
// 否则"告警在数据库里是对的、在界面上不存在"就原样重演一次(IOD-1b 的形状)。
// 所以编码进查询串,由落地页翻成句子(翻译留在服务端渲染那一侧)。
export function warningCodesFrom(data: unknown): string[] {
    const w = (data as { warnings?: unknown } | null | undefined)?.warnings
    return Array.isArray(w) ? w.map((x) => String(x ?? '').trim()).filter(Boolean) : []
}

export function warnQuery(codes: string[]): string {
    return codes.length > 0 ? `?warn=${encodeURIComponent(JSON.stringify(codes))}` : ''
}

// 落地页那一侧:查询串坏掉就当作没有告警(【不抛】—— 一个畸形的 URL 不该把
// 一个已经成功的收货变成一个错误页)。
export function warnCodesFromParam(v: string | undefined): string[] {
    if (!v) return []
    try {
        const parsed = JSON.parse(v)
        return Array.isArray(parsed) ? parsed.map((x) => String(x ?? '').trim()).filter(Boolean) : []
    } catch {
        return []
    }
}

export async function localizeStockWarnings(raw: unknown): Promise<string[]> {
    if (!Array.isArray(raw)) return []
    const t = await getTranslations()
    const out: string[] = []
    for (const item of raw) {
        const s = String(item ?? '').trim()
        if (!s) continue
        const match = s.match(CODE_RE)
        if (!match || !STOCK_WARNING_CODES.has(match[1])) {
            out.push(s)
            continue
        }
        const params: Record<string, string> = {}
        if (match[2]) {
            match[2].split('|').forEach((v, i) => {
                params[String(i)] = v
            })
        }
        out.push(t('stock.warnings.' + match[1], params))
    }
    return out
}
