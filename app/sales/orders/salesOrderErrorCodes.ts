import { getTranslations } from '@/lib/i18n/server'

// SO-1:销售订单的具名拒绝。【与库存那一族同一个形状】:不在集合里的
// 是真正未编码的数据库错误,原样返回 —— 看得见才修得掉(IOD-1b 的教训)。
const SALES_ORDER_ERROR_CODES = new Set([
    'SO_NOT_FOUND',
    'SO_NO_LINES',
    'SO_TRANSITION_NOT_ALLOWED',
    'SO_CANCEL_REASON_REQUIRED',
    'SO_CUSTOMER_ON_HOLD',
    'SO_CONFIRMED_IMMUTABLE',
    'SO_STATUS_NOT_EDITABLE',
    'SO_NOT_ISSUABLE',
    'SO_ISSUE_IMMUTABLE',
    'SO_HISTORY_IMMUTABLE',
    // SO-2:预留与释放。【操作员真会撞上前六条】—— 预留是一个日常动作,
    // 而它的每一条拒绝都在说一件人听得懂的事(单还没确认、这不是产出批次、
    // 物料对不上、这一行已经许满了、桶里没那么多货)。不接成句子,屏幕上
    // 就是一串 SO_RESERVE_EXCEEDS_LINE|25|20|0(IOD-1b 付过的那笔账)。
    'SO_RESERVE_QTY_INVALID',
    'SO_RESERVE_ORDER_NOT_CONFIRMED',
    'SO_RESERVE_OUTPUT_ONLY',
    'SO_RESERVE_MATERIAL_MISMATCH',
    'SO_RESERVE_EXCEEDS_AVAILABLE',
    'SO_RESERVE_EXCEEDS_LINE',
    'SO_RESERVATION_NOT_FOUND',
    'SO_RESERVATION_ALREADY_RELEASED',
    'SO_RELEASE_REASON_REQUIRED',
    'SO_RELEASE_EXCEEDS',
    // 结构性守卫:正常路径撞不到,但撞上时必须说人话而不是抛触发器原文。
    'SO_RESERVATION_IMMUTABLE',
    'SO_CANCEL_RESERVATIONS_LEFT',
    // SO-3b:发货。【前四条操作员真会撞上】—— 这一行还没开票、选中的预留已经
    // 被发过/释放过、数量超出那条预留、这张单的状态发不了货。
    'SHIP_DATE_REQUIRED',
    'SO_SHIP_ORDER_NOT_SHIPPABLE',
    'SO_SHIP_NO_LINES',
    'SO_SHIP_NOT_RESERVED',
    'SO_SHIP_NOT_INVOICED',
    'SO_SHIP_EXCEEDS_RESERVATION',
    'SO_RESERVATION_ALREADY_SHIPPED',
    // 结构性断言:正常路径撞不到,撞上时必须说人话
    'SO_SHIP_LINES_LOST',
    'SHIPMENT_IMMUTABLE',
    'SHIPMENT_NOT_FOUND',
    // SO-2b:建单收归一扇门(create_sales_order)。【前四条操作员真会撞上】——
    // 客户被删了、日期空着、币种没选、汇率填了 0;LINE_INVALID 点名【第几行、
    // 哪一格】,因为表单上有二十个格子,一句"某一行不合法"等于让人自己去数。
    'SO_CREATE_CUSTOMER_INVALID',
    'SO_CREATE_FX_INVALID',
    'SO_CREATE_NO_LINES',
    'SO_CREATE_LINE_INVALID',
    // 结构性断言:正常路径撞不到,撞上时必须说人话。
    'SO_CREATE_LINES_LOST',
    // 与库存那一族共用的两个码(建单也会撞上):日期必填、币种不认识
    'ORDER_DATE_REQUIRED',
    'CURRENCY_INVALID',
    // SO-1b:改单。【前六条操作员天天会撞上】—— 这张单改不了、忘了写理由、
    // 这一行已经开了票、砍到已发之下、砍到预留之下、以及三种"这一行删不掉"。
    // 每一条都在说一件人听得懂的事,而且都带着【下一步】:作废那张票、
    // 先释放预留、改成正好等于已发、另起一行。
    'SO_NOT_AMENDABLE',
    'SO_AMEND_REASON_REQUIRED',
    'SO_AMEND_LINE_INVOICED',
    'SO_LINE_BELOW_SHIPPED',
    'SO_LINE_BELOW_RESERVED',
    'SO_LINE_HAS_SHIPMENTS',
    'SO_LINE_HAS_INVOICE',
    'SO_LINE_HAS_RESERVATIONS',
    // SO-1b fu1:【第四个名字,而且它不可操作】—— 一条释放过的预留、一行作废了的
    // 发票,都是只增不改的档案,而外键盯的是订单行【在不在】,不是它活不活。
    // 不并进上面那条"请先释放预留":对一条已经释放过的预留,那句话无解,
    // 而一个指不出下一步的消息与一句外键约束名一样没用。
    'SO_LINE_HAS_RECORD',
    'SO_AMEND_LINE_INVALID',
    // 结构性:正常路径撞不到(表单只按 id 删、只递这张单上的行),撞上时说人话
    'SO_LINE_NOT_FOUND',
    'SO_LINE_REMOVE_NEEDS_ID',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export function isSalesOrderErrorCode(message: string | null | undefined): boolean {
    const m = (message ?? '').trim().match(CODE_RE)
    return !!m && SALES_ORDER_ERROR_CODES.has(m[1])
}

export async function localizeSalesOrderError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    const t = await getTranslations()
    if (match && match[1] === 'PERMISSION_DENIED') return t('common.restricted')
    if (!match || !SALES_ORDER_ERROR_CODES.has(match[1])) return raw
    const params: Record<string, string> = {}
    if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return t('sales.errors.' + match[1], params)
}
