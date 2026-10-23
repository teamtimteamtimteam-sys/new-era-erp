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
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xNum, xMoney } from '@/lib/export/cells'

export type BreachRow = {
    key: string
    purchaseOrderCode: string
    contractCode: string
    inboundBatchCode: string
    metal: string
    contentPct: string
    /** TABLE-EXPORT-2b-1:实测含量的原始数(%) */
    contentPctRaw: number
    requiredLabel: string
}

export type ContractListRow = {
    id: string
    code: string
    sideLabel: string
    title: string
    effectiveFrom: string
    /** TABLE-EXPORT-2b-1:生效 / 失效的原始日历日 */
    effectiveFromRaw: string
    effectiveToRaw: string | null
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
    /** TABLE-EXPORT-2b-1:计价比例的原始数(%) */
    payablePctRaw: number
}

export type SettleTermRow = {
    id: string
    contractCode: string
    basisLabel: string
    partyLabel: string
    /** null = 未写明拆分上限。 */
    splittingLabel: string | null
    /** TABLE-EXPORT-2b-1:拆分上限的原始数(%);null = 未写明 */
    splittingPct: number | null
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
    /** TABLE-EXPORT-2b-1:结算金额的原始数(USD —— 币种写在表头上) */
    amountUsd: number
}

export function BreachesTable({ rows }: { rows: BreachRow[] }) {
    const t = useTranslations()
    // ★ 手机上留【单据】与【实测】—— 单据是身份,实测值是"违反"这件事的证据。
    const columns: ExportableColumn<BreachRow>[] = [
        { key: 'doc', header: t('contracts.colDocument'), priority: true, className: 'text-sm', render: (r) => r.purchaseOrderCode, exportAs: (r) => xText(r.purchaseOrderCode) },
        { key: 'contract', header: t('contracts.colContract'), className: 'text-sm', render: (r) => r.contractCode, exportAs: (r) => xText(r.contractCode) },
        { key: 'batch', header: t('contracts.colBatch'), className: 'text-sm', render: (r) => r.inboundBatchCode, exportAs: (r) => xText(r.inboundBatchCode) },
        { key: 'metal', header: t('contracts.colMetal'), className: 'text-sm', render: (r) => r.metal, exportAs: (r) => xText(r.metal) },
        { key: 'measured', header: t('contracts.colMeasured'), priority: true, align: 'right', className: 'text-sm', render: (r) => r.contentPct, exportAs: (r) => xNum(r.contentPctRaw, 'pct', '%') },
        { key: 'required', header: t('contracts.colRequired'), className: 'text-sm', render: (r) => r.requiredLabel, exportAs: (r) => xText(r.requiredLabel) },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} className="mb-6"
        exportSpec={{ name: 'contract-breaches', title: t('contracts.breachTitle') }} />
}

export function ContractListTable({ rows }: { rows: ContractListRow[] }) {
    const t = useTranslations()
    // ★ 手机上留【合同号】与【标题】—— 合同号是身份,标题是"这是哪一份合同"。
    const columns: ExportableColumn<ContractListRow>[] = [
        {
            key: 'code', header: t('contracts.colCode'), priority: true, className: 'text-sm', exportAs: (r) => xText(r.code),
            render: (r) => (
                <Link href={`/contracts/${r.id}`} className="hover:underline app-link">{r.code}</Link>
            ),
        },
        { key: 'side', header: t('contracts.colSide'), className: 'text-sm', render: (r) => r.sideLabel, exportAs: (r) => xText(r.sideLabel) },
        { key: 'title', header: t('contracts.colTitle'), priority: true, className: 'text-sm', render: (r) => r.title, exportAs: (r) => xText(r.title) },
        {
            key: 'period', header: t('contracts.colPeriod'), className: 'text-sm',
            // 一段日期装不进一个日期格 —— 用原始日历日拼成文字(docs/table-export.md「What a cell cannot hold」)
            exportAs: (r) => xText(`${r.effectiveFromRaw} → ${r.effectiveToRaw ?? t('contracts.openEnded')}`),
            render: (r) => (
                <>
                    {r.effectiveFrom} →{' '}
                    {/* 【无固定期限不是"忘了填"】具名,不留白 */}
                    {r.effectiveTo ?? <span className="text-xs text-gray-500">{t('contracts.openEnded')}</span>}
                </>
            ),
        },
        { key: 'status', header: t('contracts.colStatus'), className: 'text-sm', render: (r) => r.statusLabel, exportAs: (r) => xText(r.statusLabel) },
        {
            key: 'terms', header: t('contracts.colTerms'), className: 'text-sm',
            exportAs: (r) => xText(r.termsLabel ?? t('contracts.noHeadlineTerms')),
            render: (r) => r.termsLabel ?? <span className="text-xs text-gray-500">{t('contracts.noHeadlineTerms')}</span>,
        },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }}
        exportSpec={{ name: 'contracts', title: t('contracts.listTitle') }} />
}

export function PricingTermsTable({ rows }: { rows: PricingTermRow[] }) {
    const t = useTranslations()
    // ★ 手机上留【合同号】与【指数】—— 合同号是身份,指数是"按什么计价"的答案。
    const columns: ExportableColumn<PricingTermRow>[] = [
        { key: 'code', header: t('contracts.colCode'), priority: true, className: 'text-sm', render: (r) => r.contractCode, exportAs: (r) => xText(r.contractCode) },
        { key: 'metal', header: t('contracts.pricing.colMetal'), className: 'text-sm', render: (r) => r.metal, exportAs: (r) => xText(r.metal) },
        { key: 'baseEvent', header: t('contracts.pricing.colBaseEvent'), className: 'text-sm', render: (r) => r.baseEventLabel, exportAs: (r) => xText(r.baseEventLabel) },
        { key: 'qp', header: t('contracts.pricing.colQp'), className: 'text-sm', render: (r) => r.qpLabel, exportAs: (r) => xText(r.qpLabel) },
        { key: 'index', header: t('contracts.pricing.colIndex'), priority: true, className: 'text-sm', render: (r) => r.indexCode, exportAs: (r) => xText(r.indexCode) },
        { key: 'payable', header: t('contracts.pricing.colPayable'), className: 'text-sm', render: (r) => r.payablePct, exportAs: (r) => xNum(r.payablePctRaw, 'pct', '%') },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.key} phone={{ mode: 'columns' }} className="mb-4 max-w-4xl"
        exportSpec={{ name: 'contract-pricing-terms', title: t('contracts.pricing.termsTitle') }} />
}

export function SettlementTermsTable({ rows }: { rows: SettleTermRow[] }) {
    const t = useTranslations()
    // ★ 手机上留【合同号】与【计重口径】—— 口径是这一段存在的理由(SETTLE-1)。
    const columns: ExportableColumn<SettleTermRow>[] = [
        { key: 'code', header: t('contracts.colCode'), priority: true, className: 'text-sm', render: (r) => r.contractCode, exportAs: (r) => xText(r.contractCode) },
        { key: 'basis', header: t('contracts.settlement.colBasis'), priority: true, className: 'text-sm', render: (r) => r.basisLabel, exportAs: (r) => xText(r.basisLabel) },
        { key: 'party', header: t('contracts.settlement.colSettlingParty'), className: 'text-sm', render: (r) => r.partyLabel, exportAs: (r) => xText(r.partyLabel) },
        {
            key: 'splitting', header: t('contracts.settlement.colSplitting'), className: 'text-sm',
            exportAs: (r) => (r.splittingPct == null ? xText(t('contracts.settlement.splittingNotStated')) : xNum(r.splittingPct, 'pct', '%')),
            render: (r) =>
                r.splittingLabel ?? <span className="text-gray-500">{t('contracts.settlement.splittingNotStated')}</span>,
        },
        { key: 'refining', header: t('contracts.settlement.colRefining'), className: 'text-sm', render: (r) => r.refiningLabel, exportAs: (r) => xText(r.refiningLabel) },
        { key: 'penalty', header: t('contracts.settlement.colPenalty'), className: 'text-sm', render: (r) => r.penaltyLabel, exportAs: (r) => xText(r.penaltyLabel) },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} className="mb-2 max-w-5xl"
        exportSpec={{ name: 'contract-settlement-terms', title: t('contracts.settlement.termsTitle') }} />
}

export function SettlementsTable({ rows }: { rows: SettlementRow[] }) {
    const t = useTranslations()
    // ★ 手机上留【合同号】与【金额】—— 4 列表;金额是一条已记录结算的要点。
    const columns: ExportableColumn<SettlementRow>[] = [
        { key: 'order', header: t('contracts.settlement.colOrder'), priority: true, className: 'text-sm', render: (r) => r.contractCode, exportAs: (r) => xText(r.contractCode) },
        { key: 'basis', header: t('contracts.settlement.colBasis'), className: 'text-sm', render: (r) => r.basisLabel, exportAs: (r) => xText(r.basisLabel) },
        {
            key: 'party', header: t('contracts.settlement.colUsedParty'), className: 'text-sm',
            // 格里两行都是字(用了哪一方 + 合同点名的是不是它)—— 照屏幕写成一串;后一句不能丢(SETTLE-1)
            exportAs: (r) => xText(`${r.partyLabel} (${r.partyNote})`),
            render: (r) => (
                <>
                    {r.partyLabel}
                    {/* ★【"没有那一方的化验"与"那一方的结果没被用"必须【不一样】】★
                        这里说的是后者:结果在,只是最后算数的不是它。 */}
                    <span className="block text-xs mt-1 text-amber-800">{r.partyNote}</span>
                </>
            ),
        },
        { key: 'amount', header: t('contracts.settlement.colAmount'), priority: true, className: 'text-sm', render: (r) => r.amount, exportAs: (r) => xMoney(r.amountUsd) },
    ]
    return <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} className="mb-2 max-w-5xl"
        exportSpec={{ name: 'contract-settlements', title: t('contracts.settlement.settlementsTitle') }} />
}
