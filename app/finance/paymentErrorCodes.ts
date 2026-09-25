import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'
import { localizeSelfApproval } from '@/lib/selfApproval'
import { localizeWhtError } from './whtErrorCodes'

// record_payment / reverse_payment 抛出的错误码(端口自 financeErrorCodes.ts)。
// FX_RATE_REQUIRED / PERIOD_LOCKED 复用 finance.errors 里已有的文案。
// 不在此集合内的,是真正的(未编码的)DB/约束错误,交给共用兜底 lib/machine-text.ts。
const PAYMENT_ERROR_CODES = new Set([
    // AP-RECON-1 Batch B:三条日期规矩(Tim AP-RECON-1 Q7)—— 每一条都成句子。
    'POSTING_DATE_BEYOND_CURRENT_MONTH', 'DOCUMENT_DATE_IN_FUTURE', 'REVERSAL_BEFORE_ORIGINAL',
    'PAYMENT_DATE_REQUIRED',
    'ALLOC_CURRENCY_MISMATCH', 'TRANSFER_SAME_ACCOUNT', 'TRANSFER_AMOUNTS_UNEQUAL',
    'TRANSFER_NOT_FOUND', 'TRANSFER_ALREADY_REVERSED', 'DATE_REQUIRED',
    'FX_RATE_MISSING', 'FX_RATE_NOT_ACCEPTED',
    'DIRECTION_INVALID', 'COUNTERPARTY_NOT_FOUND', 'AMOUNT_INVALID',
    'FX_RATE_REQUIRED', 'BANK_INVALID',
    'ALLOC_WRONG_SIDE', 'ALLOC_WRONG_PARTY', 'ALLOC_UNPRICED',
    'ALLOC_EXCEEDS', 'ALLOC_EXCEEDS_PAYMENT', 'PERIOD_LOCKED',
    // SOD-1:建收款人的人不得对该收款人付款。由 payments 上的触发器抛出,
    // 所以 record_payment 与任何直连写入都会撞上它。解析到 finance.errors.*。
    'SOD_PAYEE_AND_PAY',
    // PAY-1:冲销那条路上的三个码。此前它们【不在集合里】,于是 localize 把原文
    // 原样吐了回去 —— 屏幕上就是 PAYMENT_ALREADY_REVERSED 这样一串机器串。
    // (★ 这一句说的是 PAY-1 之前的历史。BUGFIX-1b 之后兜底不再原样吐,
    //   而【认出这个码】仍然比兜底好:兜底只给码,这里给的是一句说明。)
    // REVERSAL_DATE_REQUIRED 的文案 FIN-10 就写好了(finance.errors 下),
    // 只是没有人把这个码编进任何一个集合,所以那句人话一直没被用上。
    'PAYMENT_NOT_FOUND', 'PAYMENT_ALREADY_REVERSED', 'REVERSAL_DATE_REQUIRED',
    // FIN-22 / FA-1a:固定资产。处置与投用经这条路报出来(月结的动作都走
    // month-end/actions.ts,而它统一用这个本地化器)。
    'ASSET_NOT_FOUND', 'ASSET_ALREADY_DISPOSED', 'ASSET_ALREADY_IN_SERVICE',
    'ASSET_DISPOSED', 'DISPOSAL_BEFORE_ACQUISITION', 'PROCEEDS_INVALID',
    'IN_SERVICE_BEFORE_ACQUISITION',
    // EQP-1c-a:资产卡的【第二扇门】(create_fixed_asset)与它带来的一条新规矩。
    // 【现在还没有屏幕在调它 —— 码先备好是刻意的】EQP-1c 接上界面那天,
    // 没备好的码就是打到操作员脸上的裸管道串(CMP-2 为这件事付过账)。
    'ASSET_HAS_NO_COST', 'ASSET_ACQUISITION_DATE_REQUIRED', 'ASSET_CATEGORY_INVALID',
    'ASSET_DESCRIPTION_REQUIRED', 'ASSET_LIFE_INVALID',
    // FA-1a:折旧还欠着就锁不进去 —— 这一条会在月结的关账按钮上冒出来
    'DEPRECIATION_OUTSTANDING',
    // GST-2:新加坡的供应时点是【开票与收款孰早】。开票那一半实现了;
    // 收款那一半 —— 一笔先于任何发票收到的客户款 —— 实现不了(那一刻没有
    // 任何东西说得出它对应哪一项供应),所以它被【按名拦住】而不是无声放过。
    // 文案在 finance.errors 下,与这个本地化器的其余码同一处。
    'GST_UNALLOCATED_RECEIPT_UNSUPPORTED',
    // PAY-REQ-1(Tim 2026-09-23):钱离开之前要先批。出款与冲销从此经一张付款申请
    // (提 → CFO 批 → 付),record_payment 对非豁免的出款、reverse_payment 对一切冲销
    // 按名拒并指路;申请本身的生命周期那几个码也在这里。【每一条都要说出下一步】。
    'PAYMENT_REQUEST_REQUIRED', 'PAYMENT_REQUEST_NOT_REQUIRED', 'PAYMENT_REQUEST_TARGET_RESERVED', 'PAYMENT_REQUEST_NO_OTHER_DECIDER',
    'PAYMENT_REQUEST_NOT_FOUND', 'PAYMENT_REQUEST_NOT_OPEN', 'PAYMENT_REQUEST_NOT_SUBMITTED',
    'PAYMENT_REQUEST_NOT_APPROVED', 'PAYMENT_REQUEST_REJECT_REASON_REQUIRED',
    'PAYMENT_REQUEST_SUPPLIER_BLOCKED', 'PAYMENT_REVERSAL_REASON_REQUIRED',
    'PAYMENT_REVERSAL_ALREADY_REQUESTED', 'PAYMENT_REVERSAL_TAKES_NO_DATE',
    // 批准那一步走 require_approver_for(2):不是二级审批角色的人按名拒;审批关着时
    // 申请生下来就是 approved,decide 那一支按名拒。
    'APPROVAL_NOT_AUTHORISED', 'APPROVALS_NOT_ENABLED',
    // PAY-REQ-1 · Batch B:转账与代扣税缴纳也经申请。不认识的种类按名拒(此前会被当成付款冲销);
    // 转账、代扣税与它们的冲销执行时不收汇率;两种冲销的理由必填;一笔转账一张冲销申请。
    'PAYMENT_REQUEST_KIND_UNKNOWN', 'PAYMENT_REQUEST_TAKES_NO_RATE',
    'REVERSAL_REASON_REQUIRED', 'TRANSFER_REVERSAL_ALREADY_REQUESTED',
])

// cut 4b:record_payment 的 PO 预付分支抛的码,文案住在 purchasing.errors 下
// (同一个码在采购侧与付款侧要说同一句话)。
const PURCHASING_SIDE_CODES = new Set(['PREPAY_EXCEEDS_ESTIMATE'])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..."(同 localizeFinanceError)。
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizePaymentError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    // ★ PAY-REQ-1:四眼那两句话跨模块【只写一遍】(lib/selfApproval.ts)——
    //   decide_payment_request 抛 SELF_APPROVAL_FORBIDDEN|raiser(这张申请是你提的)。
    if (match && match[1] === 'SELF_APPROVAL_FORBIDDEN') {
        return await localizeSelfApproval((match[2] ?? '').split('|')[0] || null)
    }

    // ★ PAY-REQ-1 · Batch B:代扣税缴纳也经付款申请执行,所以申请页上会冒出 WHT_* ——
    //   它们的文案住在 wht.errors,交给那一族自己的本地化器,不在这里抄第二份。
    if (match && match[1].startsWith('WHT_')) {
        return await localizeWhtError(raw)
    }

    if (!match || (!PAYMENT_ERROR_CODES.has(match[1]) && !PURCHASING_SIDE_CODES.has(match[1]))) {
        return await fallbackForRawError(raw, 'localizePaymentError@app/finance/paymentErrorCodes.ts') // BUGFIX-1b:生码 / 数据库报错 → 一句人话 + 一个可追查的短码(人话句子原样留着)
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v // '0' -> first param, '1' -> second, ...
        })
    }

    const t = await getTranslations()
    return PURCHASING_SIDE_CODES.has(code)
        ? t('purchasing.errors.' + code, params)
        : t('finance.errors.' + code, params)
}
