'use client'

// app/components/audit/BatchAuditTrailTable.tsx
// TABLE-CONVERT-6:AUDIT-1 审计轨迹那张手搓 <table> 换成 DataTable。
//
// ★★【这张表此前【没有】手机档判断 —— 本刀是第一个做的】★★
//   转换前一处 hidden sm:table-cell 都没有。实测:390px 上要横拖
//   281px(/inbound)· 301px(/output),而行高最高到 261px —— 一行吃掉三分之一屏。
//   ⚠ 桌面 1280px 上【本来就在滚】:31px / 51px。它不是被转换推出去的。
//
// ★★【留哪三列 —— 时间 · 事件 · 明细。而「明细」这一列是被【源码自己的两条规矩】
//    留下来的,不是我挑的】★★
//   BatchAuditTrail.tsx 抬头写着三条规矩,其中两条【都住在明细那一格里】:
//     ① 接缝画在行里,而且【绝不省略那一行】—— 那几行 ⚠ 就在明细格内;
//     ② 受限不是空 —— 「受限」三个字连同它点名的模块码,也在明细格内。
//   ☞ 把明细折进展开区,等于把这两条规矩要人第一眼看见的东西藏到一次点击之后。
//     **所以它留在明面上,哪怕它是最长的一列。**
//   · 时间:身份(轨迹是一条排好序的时间线);
//   · 事件:这一行【是什么】。
//
// ★【谁 · 出处 为什么折】两样都是【认出这一行之后才问的】出处。
//   而「受限」在这两格里的那一份是重复的第二、第三遍 —— 明细那一份已经在明面上。
//
// ★★【整行发灰【原样搬过来】】看不到的那一段仍然占着行、而且仍然一眼看得出来:
//   转换前是 <tr className={r.may_view ? '' : 'bg-gray-50'}>,现在走组件的
//   rowClassName prop(CONV-4 建的那一个)。**规矩 ② 在 390px 上因此仍然成立。**
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

/** 服务端压平好的一行。`whoNode` 是【服务端渲染好的 <ActorName/>】—— 见下。 */
export type AuditTableRow = {
    key: string
    mayView: boolean
    whenText: string
    /** 业务日期与记账时刻不同时才有;相同就是 null(重复一遍不是信息) */
    bizDateLine: string | null
    whatText: string
    /** summarise(r) || '—';无权时不给 */
    detailText: string | null
    /** 无权时点名是哪个模块 */
    needsModuleText: string | null
    /** 已经翻好的接缝句子,逐条画 */
    seams: string[]
    /**
     * ★ ActorName 是【异步服务端组件】,进不了客户端的 render 函数。
     *   而 ActorName.tsx 抬头明写「谁做的只有一种答法 … 本刀不再造第二套词汇」——
     *   所以这里【不重算名字】,而是把服务端渲染好的那个节点原样带过来。
     */
    whoNode: React.ReactNode
    sourceHref: string | null
    sourceText: string
}

export default function BatchAuditTrailTable({ rows }: { rows: readonly AuditTableRow[] }) {
    const t = useTranslations()

    const columns: Column<AuditTableRow>[] = [
        {
            key: 'when',
            header: t('auditTrail.colWhen'),
            // ★ 身份 —— 手机上留下。
            priority: true,
            className: 'text-gray-600',
            render: (r) => (
                <>
                    <div className="text-xs">{r.whenText}</div>
                    {/* 3b:业务日期与记账时刻【不同时】两个都印。 */}
                    {r.bizDateLine && <div className="text-xs text-gray-500">{r.bizDateLine}</div>}
                </>
            ),
        },
        {
            key: 'what',
            header: t('auditTrail.colWhat'),
            // ★ 这一行是什么事 —— 手机上留下。
            priority: true,
            render: (r) => r.whatText,
        },
        {
            key: 'detail',
            header: t('auditTrail.colDetail'),
            // ★ 规矩 ①② 都住在这一格里 —— 手机上留下。理由见抬头。
            priority: true,
            render: (r) => (
                <>
                    {r.mayView ? (
                        r.detailText
                    ) : (
                        // ② 受限:点名是哪个模块,不是一格空白
                        <span className="text-gray-500">
                            {t('common.restricted')}
                            <span className="ml-1 text-xs text-gray-400">{r.needsModuleText}</span>
                        </span>
                    )}
                    {/* ① 接缝:逐条画在这一行里 */}
                    {r.seams.length > 0 && (
                        <ul className="mt-1 space-y-0.5">
                            {r.seams.map((s) => (
                                <li key={s} className="text-xs text-amber-700">
                                    ⚠ {s}
                                </li>
                            ))}
                        </ul>
                    )}
                </>
            ),
        },
        {
            key: 'who',
            header: t('auditTrail.colWho'),
            render: (r) => r.whoNode,
        },
        {
            key: 'source',
            header: t('auditTrail.colSource'),
            render: (r) =>
                r.mayView && r.sourceHref ? (
                    <Link href={r.sourceHref} className="hover:underline app-link">
                        {r.sourceText}
                    </Link>
                ) : r.mayView ? (
                    r.sourceText
                ) : (
                    <span className="text-gray-400">{t('common.restricted')}</span>
                ),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.key}
            phone={{ mode: 'columns' }}
            // 整行发灰原样搬过来 —— 「受限不是空」在手机上也看得出来。
            rowClassName={(r) => (r.mayView ? undefined : 'bg-gray-50')}
            // 空态搬进 empty prop,【同一个 key】;旧那一支已删。
            empty={t('auditTrail.empty')}
        />
    )
}
