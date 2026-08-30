import { getTranslations } from '@/lib/i18n/server'

// record_output_sale 抛出的错误码。未编码的其它错误用 saveError 包一层原文。
// 镜像 app/processing/errorCodes.ts 的 CODE|params 宽松解析。
const SALE_ERROR_CODES = new Set([
    'SALE_DATE_REQUIRED',
    'FX_RATE_MISSING', 'FX_RATE_NOT_ACCEPTED',
    'OUTPUT_NOT_FOUND', 'OUTPUT_DELETED', 'SALE_QTY_INVALID', 'SALE_EXCEEDS_REMAINING',
    // cut 1 — 销售必须带价
    'SALE_PRICE_INVALID', 'CURRENCY_INVALID', 'FX_RATE_REQUIRED',
    // SAL-B 的信用管控。【拒绝点了三个数,却没人读得懂】—— 这两个码当时写进了
    // record_output_sale 却没写文案,于是屏幕上是一串
    // CREDIT_LIMIT_EXCEEDED|ZZ-C3|10000|8820|2000。管控的全部意义就是把限额、
    // 当前敞口、这一单的金额说清楚;说成机器码等于没说。
    'CREDIT_LIMIT_EXCEEDED', 'CREDIT_HOLD',
    // SAL-A:同一块面板上的【报价】按钮走 price_output_sale。这四个是它独有的拒绝,
    // 同样一直没有文案 —— 缺行情与买卖方向搞反是报价路径上最常见的两种,
    // 与信用拦截只隔一个按钮,一并接上。
    'OUTPUT_BATCH_NOT_FOUND', 'NO_METAL_CONTENT', 'FORMULA_DIRECTION', 'METAL_PRICE_MISSING',
    'FORMULA_NOT_FOUND', 'FORMULA_INACTIVE', 'REFERENCE_DATE_REQUIRED', 'QUANTITY_INVALID',
    // METAL-2:按报价币种未声明的指数计价会被拦下(SMM 今天就是这样)。
    // 这条拒绝要出现在【报价按钮】旁边,否则人只会看到一串机器码。
    'INDEX_CURRENCY_NOT_STATED', 'PRICE_INDEX_UNKNOWN',
    // PROC-BUILD-1(R5):可售性。**三条句子,三种下一步动作,一条都不许长得像另一条** ——
    // SALE_FORM_NOT_SALEABLE 是"法律不许卖"(没有旁路);SALE_FORM_NOT_SET 是
    // "这一批的形态没设,所以判断不了",**它不是在说这个东西不许卖**;
    // 而库存类拒绝是第三种。把它们接成同一句话,操作员就不知道下一步该做什么。
    'SALE_FORM_NOT_SALEABLE', 'SALE_FORM_NOT_SET',
    // PROC-WIRE-1A(R5 的另一条轴):**第四句话,而不是前三句里任何一句的变体**。
    //   SALE_FORM_NOT_SALEABLE = 这个东西法律上不许卖 —— 没有旁路;
    //   SALE_FORM_NOT_SET      = 形态没设,所以【判断不了】 —— 去把形态设上;
    //   库存类               = 数量不够 —— 少卖点,或换一批;
    //   SALE_BATCH_EARMARKED   = 这一批【许给了下游工序】 —— 释放指定,或换一批。
    // 四句话四种下一步动作。**它尤其不许长得像第一句**:对正极片来说
    // "这个东西不许卖"是【假话】(may_be_sold = true),它只是这一批已经许出去了。
    'SALE_BATCH_EARMARKED',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeSaleError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const t = await getTranslations()
    const match = raw.match(CODE_RE)

    if (!match || !SALE_ERROR_CODES.has(match[1])) {
        return t('output.sale.saveError', { message: raw })
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v
        })
    }
    return t('output.sale.errors.' + code, params)
}
