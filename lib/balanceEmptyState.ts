// lib/balanceEmptyState.ts
// MES-7b-1(2026-10-16,F14 —— MES7A2CO-ROLLFORWARD-HIDDEN-WITHOUT-RUNS;MES-7b Step 0 Q25,Tim):/operation/balance 什么时候是"空的"。
//   那一页有三样东西:加工的月份、加工的行(全厂与每道工序)、库存滚动的行。MES-5b-1 只问了前两样,于是一个【没有加工单】的库
//   连库存滚动(收货、销售、注销、出给保养……)一起不见了,屏幕上只剩"还没有加工记录"。
//   ★ 判据:三样【都】空,才是空。一样都不许漏 —— scripts/check-balance-empty-state.mjs 把每一种组合跑一遍(含一格故障注入)。
//   纯函数、没有任何 import:页面与检查脚本读的是同一份(检查脚本用 Node 的 type-stripping 直接 import 这个文件)。

export function balancePageIsEmpty(counts: { months: number; lines: number; rollForward: number }): boolean {
    return counts.months === 0 && counts.lines === 0 && counts.rollForward === 0
}
