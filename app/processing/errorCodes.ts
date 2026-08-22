import { getTranslations } from '@/lib/i18n/server'
import { STATE_OPTIONS } from '@/app/inbound/options'
import { localizeMaterialError } from '@/app/materials/materialErrorCodes'

// commit_processing_run / rollback_processing_run 这两个 DB 函数 RAISE 出来的 13 个错误码。
// 不在此集合内的,是真正的(未编码的)DB/约束错误,原样返回。
const PROCESSING_ERROR_CODES = new Set([
    'PROCESS_DATE_REQUIRED',
    'COST_ENTRY_ALREADY_SETTLED', 'COST_ENTRY_IS_ESTIMATE', 'COST_ENTRY_NOT_ESTIMATE',
    'COST_ENTRY_SETTLED', 'COST_ENTRY_INVALID', 'RELIEF_MIXED_COST_TYPES',
    'NO_INPUTS', 'NO_OUTPUTS', 'LOSS_NEGATIVE', 'DUPLICATE_INPUT',
    'INPUT_QTY_INVALID', 'OUTPUT_QTY_INVALID', 'OUTPUT_NO_MATERIAL',
    'RUN_ALREADY_DELETED', 'INBOUND_NOT_FOUND', 'CONSUMED_EXCEEDS_REMAINING',
    'OUTPUT_EXCEEDS_INPUT', 'RUN_NOT_FOUND', 'OUTPUT_CONSUMED',
    // cut 3c — allocate_processing_costs 的错误码
    // (fu1: MISSING_METAL_PRICE removed — unpriced metals now skip instead of erroring)
    'RUN_NOT_COMMITTED', 'INVALID_BASIS', 'UNIT_NOT_KG',
    'NO_METAL_VALUE',
    // WO-1a/1b:工单(计划这一侧)+ 接缝。ALLOCATION_BASIS_REQUIRED 一并补上 ——
    // 它 FIN-36 就在抛了,只是从没有人把它编进来,于是屏幕上是机器串。
    'ALLOCATION_BASIS_REQUIRED',
    'WO_NOT_FOUND', 'WO_NOT_RELEASED', 'WO_NOT_DRAFT', 'WO_NOT_CANCELLABLE',
    'WO_NOT_AMENDABLE', 'WO_HAS_RUNS',
    'WO_NO_LINES', 'WO_LINE_QTY_INVALID', 'WO_MATERIAL_NOT_FOUND',
    'WO_DUPLICATE_MATERIAL', 'WO_EXPECTED_QTY_INVALID',
    'WO_EXPECTED_MATERIAL_NOT_FOUND', 'WO_DUPLICATE_EXPECTED',
    'WO_CLOSE_REASON_REQUIRED', 'WO_CANCEL_REASON_REQUIRED',
    'WO_AMEND_REASON_REQUIRED', 'WO_AMEND_NO_CHANGES',
    'WO_LINE_NOT_FOUND', 'WO_LINE_BELOW_CONSUMED', 'WO_EXPECTED_NOT_FOUND',

    // ── PROC-3:什么东西可以投料。guard_processing_input 抛的三条 ──────────
    // 【三条而不是一条,因为下一步动作不同】(D1)
    //   没记过 → 去把它记下来 · 记了是坏的 → 去处理那批货 · 确定度坏 → 等化验。
    // 一条共用的码会把这个区别藏起来,而屏幕正是这个区别唯一到得了人的地方。
    'INPUT_SAFETY_STATE_NOT_RECORDED',
    'INPUT_SAFETY_STATE_NOT_FEEDABLE',
    'INPUT_CHEMISTRY_NOT_FEEDABLE',

    'ROLLBACK_REASON_REQUIRED',   // AUDEL-1b
    'DELETE_REASON_REQUIRED',   // AUDEL-1b
    'SOFT_DELETE_NO_DIRECT_UPDATE',   // AUDEL-1b
])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..." —— 即使 PostgREST 在前面包了前缀,
// 也能定位到大写下划线的 code 和它后面 |-分隔的参数。找不到已知 code 就原样返回。
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeProcessingError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    if (!match || !PROCESSING_ERROR_CODES.has(match[1])) {
        // ── PROC-3:先问一句物料那一支,再判定"这是一条没编码的错" ──────────
        // **guard_processing_input 抛的不全是加工模块的码。** PROC-1 的
        // MATERIAL_NOT_PROCESSABLE 就是它抛的,句子写在 materials.errors.* 里,
        // 而这里从来没问过它 —— 于是【从 PROC-1 落地那天起,加工屏幕上那条拒绝
        // 一直是一串机器码】。实测确认,不是推测。
        // 【为什么是链而不是把码抄过来】抄一份就是第二处要跟着字典长的清单,
        // 而 materials.errors.* 已经收着五条轴的全部拒绝(外键、主键、适用性)。
        // localizeMaterialError 认不出时原样返回,所以这一链是安全的。
        const viaMaterial = await localizeMaterialError(raw)
        if (viaMaterial !== raw) return viaMaterial
        return raw // genuine non-coded DB error → surface verbatim
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v // '0' -> first param, '1' -> second, ...
        })
    }

    const t = await getTranslations()

    // ── AUDEL-3:【存进库里的状态值不能原样塞进句子】────────────────────────
    // Tim 的验收里看到过一句英文拒绝里夹着中文:
    //     "output batch OUT-… has already been touched (state=部分售出, …)"
    // 原因是 output_batches.state 的【取值本身就是中文】
    //     CHECK (state IN ('库存中','部分售出','已售罄'))
    // 而 OUTPUT_CONSUMED 把它当参数直接插进模板。界面上早就有这份映射
    // (app/inbound/options.ts 的 STATE_OPTIONS,value → labelKey),
    // 这里接上它 —— 不是新写一份对照表。
    // 【认不出的取值原样显示】而不是猜:一个猜出来的状态与一个说错了的状态,
    // 在屏幕上长得一模一样。
    if (code === 'OUTPUT_CONSUMED' && params['1']) {
        const key = STATE_OPTIONS.find((o) => o.value === params['1'])?.labelKey
        if (key) params['1'] = t(key)
    }

    return t('processing.errors.' + code, params)
}
