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
    return raw // 真正的非编码错误 —— 原样呈上,不要吞掉
}
