'use client'

// app/contracts/ContractsTables.tsx
// CONV-5 · 合同那一屏上的【五张】行登记簿。
//
// ★★【这一页是报告体,但它【装着】五张真正的登记簿】★★
// Tim 在 CONV-5 Q2 的裁定:真正的行登记簿才换,报告体保持原样。这一页两样都有:
//   换掉的五张 —— 违反 / 合同清单 / 指数计价条款 / 结算口径 / 已记录的结算;
//   保持原样的 —— 覆盖率块、两个"建了什么/还不能做什么"的琥珀块、开市日历那份
//   项目符号清单、以及每一段前后那些具名的缺席句。后者【不是表】,
//   把它们压成表会毁掉它们正在做的那件事。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type BreachRow = {
    key: string
    purchaseOrderCode: string
    contractCode: string
    inboundBatchCode: string
    metal: string
    contentPct: string
    requiredLabel: string
}

export type ContractListRow = {
    id: string
    code: string
    sideLabel: string
    title: string
    effectiveFrom: string
    /** null = 无固定期限 —— 【不是"忘了填"】,具名,不留白。 */
    effectiveTo: string | null
    statusLabel: string
    /** null = 没有头条条款。 */
    termsLabel: string | null
}

export type PricingTermRow = {
    key: string
    contractCode: string
    metal: string
    baseEventLabel: string
    qpLabel: string
    indexCode: string
    payablePct: string
}

export type SettleTermRow = {
    id: string
    contractCode: string
    basisLabel: string
    partyLabel: string
    /** null = 未写明拆分上限。 */
    splittingLabel: string | null
    refiningLabel: string
    penaltyLabel: string
}

export type SettlementRow = {
    id: string
    contractCode: string
    basisLabel: string
    partyLabel: string
    /** ★「没有那一方的化验」与「那一方的结果没被用」必须【不一样】—— 这是后者。 */
    partyNote: string
    amount: string
}

export function BreachesTable({ rows }: { rows: BreachRow[] }) {
    const t = useTranslations()
    // ★ 手机上留【单据】与【实测】—— 单据是身份,实测值是"违反"这件事的证据。
    const columns: Column<BreachRow>[] = [
        { key: 'doc', header: t('contracts.colDocument'), priority: true, className: 'font-mono text-sm', render: (r) => r.purchaseOrderCode },
        { key: 'contract', header: t('contracts.colContract'), className: 'font-mono text-sm', render: (r) => r.contractCode },
        { key: 'batch', header: t('contracts.colBatch'), className: 'font-mono text-sm', render: (r) => r.inboundBatchCode },
        { key: 'metal', header: t('contracts.colMetal'), className: 'text-sm', render: (r) => r.metal },
        { key: 'measured', header: t('contracts.colMeasured'), priority: true, align: 'right', className: 'text-sm font-mono', render: (r) => r.contentPct },
        { key: 'required', header: t('contracts.colRequired'), className: 'text-sm', render: (r) => r.requiredLabel },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} className="mb-6" />
}

export function ContractListTable({ rows }: { rows: ContractListRow[] }) {
    const t = useTranslations()
    // ★ 手机上留【合同号】与【标题】—— 合同号是身份,标题是"这是哪一份合同"。
    const columns: Column<ContractListRow>[] = [
        {
            key: 'code', header: t('contracts.colCode'), priority: true, className: 'font-mono text-sm',
            render: (r) => (
                <Link href={`/contracts/${r.id}`} className="text-blue-600 hover:underline">{r.code}</Link>
            ),
        },
        { key: 'side', header: t('contracts.colSide'), className: 'text-sm', render: (r) => r.sideLabel },
        { key: 'title', header: t('contracts.colTitle'), priority: true, className: 'text-sm', render: (r) => r.title },
        {
            key: 'period', header: t('contracts.colPeriod'), className: 'text-sm',
            render: (r) => (
                <>
                    {r.effectiveFrom} →{' '}
                    {/* 【无固定期限不是"忘了填"】具名,不留白 */}
                    {r.effectiveTo ?? <span className="text-xs text-gray-500">{t('contracts.openEnded')}</span>}
                </>
            ),
        },
        { key: 'status', header: t('contracts.colStatus'), className: 'text-sm', render: (r) => r.statusLabel },
        {
            key: 'terms', header: t('contracts.colTerms'), className: 'text-sm',
            render: (r) => r.termsLabel ?? <span className="text-xs text-gray-500">{t('contracts.noHeadlineTerms')}</span>,
        },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} />
}

export function PricingTermsTable({ rows }: { rows: PricingTermRow[] }) {
    const t = useTranslations()
    // ★ 手机上留【合同号】与【指数】—— 合同号是身份,指数是"按什么计价"的答案。
    const columns: Column<PricingTermRow>[] = [
        { key: 'code', header: t('contracts.colCode'), priority: true, className: 'font-mono text-sm', render: (r) => r.contractCode },
        { key: 'metal', header: t('contracts.pricing.colMetal'), className: 'text-sm', render: (r) => r.metal },
        { key: 'baseEvent', header: t('contracts.pricing.colBaseEvent'), className: 'text-sm', render: (r) => r.baseEventLabel },
        { key: 'qp', header: t('contracts.pricing.colQp'), className: 'text-sm', render: (r) => r.qpLabel },
        { key: 'index', header: t('contracts.pricing.colIndex'), priority: true, className: 'text-sm', render: (r) => r.indexCode },
        { key: 'payable', header: t('contracts.pricing.colPayable'), className: 'text-sm', render: (r) => r.payablePct },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} className="mb-4 max-w-4xl" />
}

export function SettlementTermsTable({ rows }: { rows: SettleTermRow[] }) {
    const t = useTranslations()
    // ★ 手机上留【合同号】与【计重口径】—— 口径是这一段存在的理由(SETTLE-1)。
    const columns: Column<SettleTermRow>[] = [
        { key: 'code', header: t('contracts.colCode'), priority: true, className: 'font-mono text-sm', render: (r) => r.contractCode },
        { key: 'basis', header: t('contracts.settlement.colBasis'), priority: true, className: 'text-sm', render: (r) => r.basisLabel },
        { key: 'party', header: t('contracts.settlement.colSettlingParty'), className: 'text-sm', render: (r) => r.partyLabel },
        {
            key: 'splitting', header: t('contracts.settlement.colSplitting'), className: 'text-sm',
            render: (r) =>
                r.splittingLabel ?? <span className="text-gray-500">{t('contracts.settlement.splittingNotStated')}</span>,
        },
        { key: 'refining', header: t('contracts.settlement.colRefining'), className: 'text-sm', render: (r) => r.refiningLabel },
        { key: 'penalty', header: t('contracts.settlement.colPenalty'), className: 'text-sm', render: (r) => r.penaltyLabel },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} className="mb-2 max-w-5xl" />
}

export function SettlementsTable({ rows }: { rows: SettlementRow[] }) {
    const t = useTranslations()
    // ★ 手机上留【合同号】与【金额】—— 4 列表;金额是一条已记录结算的要点。
    const columns: Column<SettlementRow>[] = [
        { key: 'order', header: t('contracts.settlement.colOrder'), priority: true, className: 'font-mono text-sm', render: (r) => r.contractCode },
        { key: 'basis', header: t('contracts.settlement.colBasis'), className: 'text-sm', render: (r) => r.basisLabel },
        {
            key: 'party', header: t('contracts.settlement.colUsedParty'), className: 'text-sm',
            render: (r) => (
                <>
                    {r.partyLabel}
                    {/* ★【"没有那一方的化验"与"那一方的结果没被用"必须【不一样】】★
                        这里说的是后者:结果在,只是最后算数的不是它。 */}
                    <span className="block text-xs mt-1 text-amber-800">{r.partyNote}</span>
                </>
            ),
        },
        { key: 'amount', header: t('contracts.settlement.colAmount'), priority: true, className: 'text-sm', render: (r) => r.amount },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} className="mb-2 max-w-5xl" />
}
