'use client'

// app/me/MyTrainingTable.tsx
// ★ TABLE-CONVERT-1(2026-09-10):从 app/me/page.tsx 里搬出来的培训记录那张表。
//   为什么必须是一个新文件,与 MyPayslipsTable.tsx 抬头同一条理由(server→client
//   的边界过不去函数),那里写全了。
//
// 【这张表【没有】列选判断要搬】—— 它转换之前一个 hidden sm:table-cell 都没有,
// 三列在 390px 上【全部看得见】。于是三列【全部】priority:那是把「今天手机上
// 三列都在」原样说了一遍,不是新加的优先级。
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type TrainingRow = {
    id: string
    trainingName: string
    provider: string | null
    /** 已按页面的 locale 格式化;读不到日期时页面给的是 '—'。 */
    completedLabel: string
    expiryLabel: string
    /**
     * 到期提示。**判断留在页面那一侧**(page.tsx 的 expiryState —— 工作准证那一处
     * 也用它,同一个"今天"),这里只把它的两半画出来。
     */
    expiry: { key: string; cls: string } | null
}

export default function MyTrainingTable({ rows, empty }: { rows: TrainingRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    const columns: Column<TrainingRow>[] = [
        {
            key: 'name', header: t('me.trainingName'), priority: true,
            render: (r) => (
                <>
                    {r.trainingName}
                    {r.provider && <span className="ml-2 text-xs text-gray-500">{r.provider}</span>}
                </>
            ),
        },
        { key: 'completed', header: t('me.completed'), priority: true, render: (r) => r.completedLabel },
        {
            key: 'expires', header: t('me.expires'), priority: true,
            render: (r) => (
                <>
                    {r.expiryLabel}
                    {r.expiry && (
                        <span className={`ml-2 rounded px-1.5 py-0.5 text-xs ${r.expiry.cls}`}>
                            {t(r.expiry.key)}
                        </span>
                    )}
                </>
            ),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={empty}
        />
    )
}
