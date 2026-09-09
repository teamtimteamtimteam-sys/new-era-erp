'use client'

// app/finance/close/CloseHistoryTable.tsx
// ★ TABLE-CONVERT-2(2026-09-10):从 app/finance/close/page.tsx 里搬出来的关账历史表。
//
// 【为什么必须是新文件】page.tsx 是 server component,而列描述符带 render 函数 ——
//   函数跨不过 server→client 的边界,留在原地【编译不过】。与 TABLE-CONVERT-1 在
//   app/me/page.tsx 上撞到的是同一条,处置也照抄:金额与时间在服务端格好再过界。
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import ReopenForm from './ReopenForm'

export type CloseHistoryRow = {
    id: string
    periodEnd: string
    /** 已在服务端截到分钟并把 T 换成空格,与转换之前逐字相同。 */
    closedAt: string
    entriesCount: number
    debits: string
    credits: string
    reopened: boolean
    reopenReason: string | null
}

export default function CloseHistoryTable({
    rows, canEdit, empty,
}: { rows: CloseHistoryRow[]; canEdit: boolean; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【期末日 · 借方 · 状态】—— TABLE-PHONE-2 的判断,一个字没改。
    //   关账历史问的是「哪个月关了、锁了多大一笔、现在还锁着没有」;一次关账
    //   借贷【按构造相等】,所以留一侧就说清了它的大小,贷方与分录数进展开区。
    //
    // ★★【第七列(重开钮)是 priority —— 这一条是【接着 TABLE-STYLE-1 / R1 往下走】★★
    //   转换之前那一列带着 hidden sm:table-cell,而那颗钮【另外画了一份在身份格里】
    //   —— 也就是说它在手机上【本来就不用点开任何东西就够得着】。
    //   组件里没有"叠在身份格里画出来"这一档:一列要么 priority(留在明面上),
    //   要么进【点一下才展开】的那一段。把它折进去 = 要先点开一行才够得着那颗钮,
    //   而那正是 R1 判过的那件事:**够不着的动作等于不存在**。
    //   ☞ 所以它 priority:true。屏幕上"不点就够得着"这件事因此【没有变】,
    //     变的是它从身份格里挪到了自己那一列 —— 与 TABLE-STYLE-1 对
    //     MyExpenseClaimsPanel 撤回钮做的处置逐字同形。
    const columns: Column<CloseHistoryRow>[] = [
        {
            key: 'periodEnd', header: t('finance.colPeriodEnd'), priority: true,
            className: 'font-mono', render: (c) => c.periodEnd,
        },
        { key: 'closedAt', header: t('finance.colClosedAt'), render: (c) => c.closedAt },
        {
            key: 'entriesCount', header: t('finance.entriesCount'), align: 'right',
            className: 'font-mono', render: (c) => c.entriesCount,
        },
        {
            key: 'debits', header: t('finance.colDebits'), align: 'right', priority: true,
            className: 'font-mono', render: (c) => c.debits,
        },
        {
            key: 'credits', header: t('finance.colCredits'), align: 'right',
            className: 'font-mono', render: (c) => c.credits,
        },
        {
            key: 'status', header: t('finance.colStatus'), priority: true,
            render: (c) => (
                <>
                    <span className={'px-2 py-1 rounded text-xs ' +
                        (c.reopened ? 'bg-amber-100 text-amber-800' : 'bg-green-100 text-green-800')}>
                        {c.reopened ? t('finance.closeStatus.reopened') : t('finance.closeStatus.active')}
                    </span>
                    {c.reopenReason && (
                        <p className="text-xs text-gray-500 mt-1">{c.reopenReason}</p>
                    )}
                </>
            ),
        },
        // ★ 空列头与转换之前逐字相同(桌面档那一列本来就没有列头);
        //   那颗钮自己带着字,所以这里【没有】新增任何 i18n key。
        {
            key: 'reopen', header: '', priority: true,
            render: (c) => (c.reopened ? null : <ReopenForm canEdit={canEdit} periodEnd={c.periodEnd} />),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(c) => c.id}
            phone={{ mode: 'columns' }}
            empty={empty}
        />
    )
}
