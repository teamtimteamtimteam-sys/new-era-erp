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
import { fallbackForRawError } from '@/lib/machine-text'

export const CONTRACT_ERROR_CODES = new Set([
    'CONTRACT_COUNTERPARTY_REQUIRED',
    'CONTRACT_TITLE_REQUIRED',
    'CONTRACT_EFFECTIVE_FROM_REQUIRED',
    'CONTRACT_KIND_INVALID',
    'CONTRACT_STATUS_INVALID',
    'CONTRACT_PERIOD_ORDER',
    'CONTRACT_PAYMENT_TERMS_INVALID',
    'CONTRACT_NOT_PERMITTED',
    // ── TERMS-EDIT-1:七张条款表的约束(见下面 CONSTRAINT_TO_CODE)──────────────────────
    'CONTRACT_GRADE_NEEDS_A_BOUND',
    'CONTRACT_GRADE_BOUNDS_ORDERED',
    'CONTRACT_GRADE_DUPLICATE',
    'CONTRACT_TERM_PCT_RANGE',
    'CONTRACT_TERM_AMOUNT_NEGATIVE',
    'CONTRACT_TERM_CHOICE_INVALID',
    'CONTRACT_INSURANCE_AMOUNT_NEEDS_CURRENCY',
    'CONTRACT_INSURANCE_COVER_REQUIRED',
    'CONTRACT_VOLUME_QUANTITY_POSITIVE',
    'CONTRACT_VOLUME_UNIT_REQUIRED',
    'CONTRACT_PRICING_DUPLICATE_METAL',
    'CONTRACT_PRICING_PAYABLE_RANGE',
    'CONTRACT_PRICING_QP_RANGE',
    'CONTRACT_SETTLEMENT_ALREADY_STATED',
    'CONTRACT_SETTLEMENT_RETENTION_DAYS',
    'CONTRACT_SETTLEMENT_SPLITTING_RANGE',
    'CONTRACT_REFINING_DUPLICATE_METAL',
    'CONTRACT_PENALTY_DUPLICATE_SUBSTANCE',
    // ── PUR-1:把一张单据挂到合同上那条路的具名拒绝 ──────────────────────────
    // ★★【这五条【一直】会被抛出,却从来没有句子 —— 因为从来没有屏幕调它】★★
    //   link_document_to_contract 是 CONTRACT-1 建的,五条拒绝早就在函数里,
    //   而全仓库【零处】调用它(2026-09-08 实测)。PUR-1 建了那扇门,
    //   于是这五条从今天起会真的打到操作员脸上 —— 不接就是
    //   `CONTRACT_NOT_ACTIVE|CON-2027-0001|draft` 这一串原文。
    //   ★ 与 SOD-1 把审批引擎那十二条一次接齐是同一件事:
    //     码是从【函数体】里逐条数出来的,不是"我碰巧撞到过哪几条"。
    'CONTRACT_NOT_ACTIVE',
    'CONTRACT_SIDE_MISMATCH',
    'CONTRACT_COUNTERPARTY_MISMATCH',
    'DOCUMENT_ALREADY_UNDER_CONTRACT',
    'CONTRACT_NOT_FOUND',
    'CONTRACT_DOCUMENT_KIND_INVALID',
    'PO_NOT_FOUND',
    'SO_NOT_FOUND',
    // ★【PERMISSION_DENIED 【不】在这里,而那是刻意的】★
    //   link_document_to_contract 确实抛得出它(它自己按合同归属那一侧
    //   require_permission),而 messages 里也早就有一句专门写给它的话。
    //   但这个 localizer 是【共用】的:创建合同那条路也调它,而那句话写的是
    //   "你没有权限把单据挂到这份合同上" —— 在创建页上说这句就是答非所问。
    //   所以它在【挂接那个 action 里】单独接(app/purchasing/orders/[id]/contractActions.ts),
    //   接在知道上下文的那一处。
])

const CONSTRAINT_TO_CODE: Record<string, string> = {
    contracts_exactly_one_counterparty: 'CONTRACT_COUNTERPARTY_REQUIRED',
    contracts_title_check: 'CONTRACT_TITLE_REQUIRED',
    contracts_kind_check: 'CONTRACT_KIND_INVALID',
    contracts_status_check: 'CONTRACT_STATUS_INVALID',
    contracts_period_order: 'CONTRACT_PERIOD_ORDER',
    contracts_payment_terms_days_check: 'CONTRACT_PAYMENT_TERMS_INVALID',
    // ── TERMS-EDIT-1(Q2):七张条款表上的每一条 CHECK / 唯一约束 / 唯一索引 ──────────────
    //   2026-09-27 读 pg_constraint + pg_indexes(postgres,基表):CHECK 与唯一约束 30 条、唯一索引 2 条,
    //   外键不在此列(它们指向下拉里选出来的字典行,屏幕上造不出一条悬空的)。
    //   ★ 按【名字】认,不按错误文本;名字互不为前缀(one_per_metal 两张表各一条,表名不同)。
    contract_grade_specs_needs_a_bound: 'CONTRACT_GRADE_NEEDS_A_BOUND',
    contract_grade_specs_bounds_ordered: 'CONTRACT_GRADE_BOUNDS_ORDERED',
    contract_grade_specs_min_pct_check: 'CONTRACT_TERM_PCT_RANGE',
    contract_grade_specs_max_pct_check: 'CONTRACT_TERM_PCT_RANGE',
    contract_grade_specs_one_per_material_metal: 'CONTRACT_GRADE_DUPLICATE',
    contract_grade_specs_one_per_metal_no_material: 'CONTRACT_GRADE_DUPLICATE',
    contract_insurance_amount_needs_currency: 'CONTRACT_INSURANCE_AMOUNT_NEEDS_CURRENCY',
    contract_insurance_obligations_cover_type_check: 'CONTRACT_INSURANCE_COVER_REQUIRED',
    contract_insurance_obligations_insured_by_check: 'CONTRACT_TERM_CHOICE_INVALID',
    contract_insurance_obligations_min_amount_check: 'CONTRACT_TERM_AMOUNT_NEGATIVE',
    contract_volume_commitments_committed_by_party_check: 'CONTRACT_TERM_CHOICE_INVALID',
    contract_volume_commitments_direction_check: 'CONTRACT_TERM_CHOICE_INVALID',
    contract_volume_commitments_period_check: 'CONTRACT_TERM_CHOICE_INVALID',
    contract_volume_commitments_quantity_check: 'CONTRACT_VOLUME_QUANTITY_POSITIVE',
    contract_volume_commitments_unit_check: 'CONTRACT_VOLUME_UNIT_REQUIRED',
    contract_pricing_terms_base_event_check: 'CONTRACT_TERM_CHOICE_INVALID',
    contract_pricing_terms_one_per_metal: 'CONTRACT_PRICING_DUPLICATE_METAL',
    contract_pricing_terms_payable_pct_check: 'CONTRACT_PRICING_PAYABLE_RANGE',
    contract_pricing_terms_qp_months_check: 'CONTRACT_PRICING_QP_RANGE',
    contract_settlement_terms_one_per_contract: 'CONTRACT_SETTLEMENT_ALREADY_STATED',
    contract_settlement_terms_penalty_basis_check: 'CONTRACT_TERM_CHOICE_INVALID',
    contract_settlement_terms_refining_charge_basis_check: 'CONTRACT_TERM_CHOICE_INVALID',
    contract_settlement_terms_sale_weight_basis_check: 'CONTRACT_TERM_CHOICE_INVALID',
    contract_settlement_terms_settling_party_check: 'CONTRACT_TERM_CHOICE_INVALID',
    contract_settlement_terms_sample_retention_days_check: 'CONTRACT_SETTLEMENT_RETENTION_DAYS',
    contract_settlement_terms_splitting_limit_pct_check: 'CONTRACT_SETTLEMENT_SPLITTING_RANGE',
    contract_refining_charges_one_per_metal: 'CONTRACT_REFINING_DUPLICATE_METAL',
    contract_refining_charges_usd_per_tonne_of_metal_check: 'CONTRACT_TERM_AMOUNT_NEGATIVE',
    contract_penalty_elements_one_per_substance: 'CONTRACT_PENALTY_DUPLICATE_SUBSTANCE',
    contract_penalty_elements_threshold_pct_check: 'CONTRACT_TERM_PCT_RANGE',
    contract_penalty_elements_usd_per_tonne_per_pct_over_check: 'CONTRACT_TERM_AMOUNT_NEGATIVE',
}

/** TERMS-EDIT-1:这一串是不是合同 / 条款表上某一条约束的原话(是 → 交给本文件;否 → 交给条款申请那一份) */
export function isContractConstraintError(message: string): boolean {
    const raw = message ?? ''
    return Object.keys(CONSTRAINT_TO_CODE).some((c) => raw.includes(c))
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
    // ★【PUR-1:按码认之前先把管道参数拆出来】★
    //   此前这一支比对的是【整串】,而它接的那七条(全来自表单校验)都是光码。
    //   link_document_to_contract 抛的是 `CONTRACT_NOT_ACTIVE|CON-2027-0001|draft`
    //   —— 带参数。不拆,`has(raw)` 永远为 false,那一串会原样落到屏幕上。
    const m = raw.match(/^([A-Z][A-Z0-9_]+)(?:\|([\s\S]*))?$/)
    if (m && CONTRACT_ERROR_CODES.has(m[1])) {
        const params: Record<string, string> = {}
        if (m[2]) m[2].split('|').forEach((v, i) => { params[String(i)] = v })
        return t('contracts.errors.' + m[1], params)
    }
    return await fallbackForRawError(raw, 'localizeContractError@app/contracts/contractErrorCodes.ts') // BUGFIX-1b:生码 / 数据库报错 → 一句人话 + 一个可追查的短码(人话句子原样留着)
}
