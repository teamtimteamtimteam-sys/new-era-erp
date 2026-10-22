// app/finance/payroll-payments/cpfDue.ts
// CPF 的到期日:薪资月的次月 14 日(PayPanel 那颗「付 CPF」钮上写着它)。
// TABLE-EXPORT-2a:从 PayPanel.tsx 里搬出来,只为了让 db/scripts/2026-10-23-table-export-2a-cpf-due-proof.mts 能【跑】它
//   (那个面板用 useRouter,离开 app router 渲染不起来)—— 函数体一个字没改。
// ★ TABLE-EXPORT-2a(Tim 2026-10-22 Q9):入参是【原始的】period_month(YYYY-MM-DD)。从前调用点传的是 formatMonth 的显示用的字
//   (「Sep 2026」/「2026年9月」),切出来 split('-') 得到 NaN,toISOString() 抛 RangeError —— 每一颗没付的公积金钮都让这一块崩掉。
export function cpfDue(periodMonth: string): string {
    const [y, m] = periodMonth.slice(0, 7).split('-').map(Number)
    return new Date(Date.UTC(m === 12 ? y + 1 : y, m === 12 ? 0 : m, 14)).toISOString().slice(0, 10)
}
