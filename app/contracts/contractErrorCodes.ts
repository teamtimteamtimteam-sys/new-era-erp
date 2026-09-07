// MANUAL-FIX-2:合同创建那条路上的具名拒绝 → 双语句子。
// 形状取自 licenceErrorCodes / commissionErrorCodes(本仓库已有十余处同形)。
//
// 【逐条从【约束】数出来的,而且约束名是【对着线上量的】,不是按惯例猜的】
//   2026-09-07 读 pg_constraint(只读查询),contracts 上的 CHECK 恰好六条:
//     contracts_exactly_one_counterparty   num_nonnulls(customer_id, supplier_id) = 1
//     contracts_title_check                btrim(title) <> ''
//     contracts_kind_check                 五个取值
//     contracts_status_check               五个状态
//     contracts_period_order               effective_to IS NULL OR >= effective_from
//     contracts_payment_terms_days_check   NULL 或 0..365
//   ★ 约束名是我们自己起的,错误文本不是 —— 所以这里按【名字】认。
//
// ★★【这一整张表是【后手】,不是第一道判据】★★
//   表单那一侧(actions.ts)在写库【之前】就把这六件事各拒一次,并把话放回
//   对应的字段旁边 —— 那是人真正会读到的位置。这里接住的是【绕过表单的写入】
//   (直接 POST、或将来别的调用点),以及 RLS 那一条:它【不可能】在应用侧先判,
//   因为要哪个码取决于对手方选的是供应商还是客户。
import { getTranslations } from '@/lib/i18n/server'

export const CONTRACT_ERROR_CODES = new Set([
    'CONTRACT_COUNTERPARTY_REQUIRED',
    'CONTRACT_TITLE_REQUIRED',
    'CONTRACT_EFFECTIVE_FROM_REQUIRED',
    'CONTRACT_KIND_INVALID',
    'CONTRACT_STATUS_INVALID',
    'CONTRACT_PERIOD_ORDER',
    'CONTRACT_PAYMENT_TERMS_INVALID',
    'CONTRACT_NOT_PERMITTED',
])

const CONSTRAINT_TO_CODE: Record<string, string> = {
    contracts_exactly_one_counterparty: 'CONTRACT_COUNTERPARTY_REQUIRED',
    contracts_title_check: 'CONTRACT_TITLE_REQUIRED',
    contracts_kind_check: 'CONTRACT_KIND_INVALID',
    contracts_status_check: 'CONTRACT_STATUS_INVALID',
    contracts_period_order: 'CONTRACT_PERIOD_ORDER',
    contracts_payment_terms_days_check: 'CONTRACT_PAYMENT_TERMS_INVALID',
}

export async function localizeContractError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const t = await getTranslations()

    for (const [constraint, code] of Object.entries(CONSTRAINT_TO_CODE)) {
        if (raw.includes(constraint)) return t('contracts.errors.' + code)
    }
    // RLS:按 SQLSTATE 的措辞认,不猜某一句文案(与 licenceErrorCodes 同一条)
    if (/row-level security|42501/i.test(raw)) {
        return t('contracts.errors.CONTRACT_NOT_PERMITTED')
    }
    if (CONTRACT_ERROR_CODES.has(raw)) {
        return t('contracts.errors.' + raw)
    }
    return raw // 真正的非编码错误 —— 原样呈上,不要吞掉
}
