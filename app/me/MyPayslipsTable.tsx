'use client'

// app/me/MyPayslipsTable.tsx
// ★ TABLE-CONVERT-1(2026-09-10):从 app/me/page.tsx 里搬出来的工资条那张表。
//
// 【为什么它必须是一个【新文件】,而不是留在 page.tsx 里】
//   app/me/page.tsx 是一个 **server component**(`export default async function`,
//   它 await supabase / cookies())。而表格组件是 'use client' 的,它的 Column
//   描述符里带 `render: (row) => ReactNode` —— **函数跨不过 server→client 那道边界**。
//   ☞ 这不是一个风格选择:留在原地转换【编译不过】。
//   ☞ 这也正是本仓库已经做了 97 次的形状:全库 97 个表格组件调用点,
//     **97 个全部住在 'use client' 文件里**,服务端页面把行喂给它们
//     (app/hr/leave/LeaveRequestsTable.tsx 是同一个模块里的先例)。
//
// 【为什么行是【在服务端格好】再传进来的】
//   币种、期间号、日期都来自页面那一侧(payroll_periods 与 formatAmount)。
//   把 toLocaleDateString 挪到客户端会让服务端渲染与水合两次结果可能不一致,
//   而那会改变屏幕上的字。**所以格式化留在原地,过界的只有字符串。**
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xMoney } from '@/lib/export/cells'

export type PayslipRow = {
    id: string
    /** 期间号;读不到期间时页面给的是 '—',与转换之前逐字相同。 */
    periodCode: string
    /** 期间月份,已按页面的 locale 格式化;没有就是 null。 */
    periodMonthLabel: string | null
    gross: string
    employerCpf: string
    employeeCpf: string
    deductions: string
    net: string
    /**
     * TABLE-EXPORT-2b-1:导出用的原始值 —— 五个金额是数(不是上面格好的字),带这一期自己的币种;
     * 期间月份是原始的 YYYY-MM-DD 的头七位。屏幕仍只画上面那几串字。
     * (payroll_lines_masked 对本人的行原样放行,所以这里的 NULL 不是遮蔽。)
     */
    periodMonthRaw: string | null
    currency: string | null
    grossRaw: number | null
    employerCpfRaw: number | null
    employeeCpfRaw: number | null
    deductionsRaw: number | null
    netRaw: number | null
}

export default function MyPayslipsTable({ rows, empty }: { rows: PayslipRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留三列 —— TABLE-PHONE-2 的判断,一个字没改:期间 · 应发 · 实发。
    //   【这张表没有状态列】,所以第三格给了第二个要紧的数:一个人在手机上翻
    //   自己的工资条,问的是「这个月应发多少、真正到手多少」—— 两头都要,
    //   少一头就没法自己对。中间那三列(雇主公积金 / 个人公积金 / 其他扣除)
    //   正是两头之间的明细,它们进展开区。
    const columns: ExportableColumn<PayslipRow>[] = [
        {
            key: 'period', header: t('me.period'), priority: true,
            // 期间号旁边那个月份写成原始的 YYYY-MM,不是屏幕上按语言格好的月份名
            exportAs: (l) => xText(l.periodMonthRaw ? `${l.periodCode} ${l.periodMonthRaw.slice(0, 7)}` : l.periodCode),
            render: (l) => (
                <>
                    {l.periodCode}
                    {l.periodMonthLabel && (
                        <span className="ml-2 text-xs text-gray-500">{l.periodMonthLabel}</span>
                    )}
                </>
            ),
        },
        {
            key: 'gross', header: t('me.gross'), align: 'right', priority: true, render: (l) => l.gross,
            exportAs: (l) => xMoney(l.grossRaw, l.currency),
        },
        {
            key: 'employerCpf', header: t('me.employerCpf'), align: 'right', render: (l) => l.employerCpf,
            exportAs: (l) => xMoney(l.employerCpfRaw, l.currency),
        },
        {
            key: 'employeeCpf', header: t('me.employeeCpf'), align: 'right', render: (l) => l.employeeCpf,
            exportAs: (l) => xMoney(l.employeeCpfRaw, l.currency),
        },
        {
            key: 'deductions', header: t('me.deductions'), align: 'right', render: (l) => l.deductions,
            exportAs: (l) => xMoney(l.deductionsRaw, l.currency),
        },
        {
            key: 'net', header: t('me.net'), align: 'right', priority: true,
            className: 'font-medium', render: (l) => l.net,
            exportAs: (l) => xMoney(l.netRaw, l.currency),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(l) => l.id}
            phone={{ mode: 'columns' }}
            empty={empty}
            exportSpec={{ name: 'me-payslips', title: t('me.payslips') }}
        />
    )
}
