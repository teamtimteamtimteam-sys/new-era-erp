// app/inventory/reports/reportShared.ts
// RPT-1:四张报表共用的取数与导出零件。
//
// 【为什么共用】页面、导出、PDF 三处必须回答【同一个问题】。三处各写一份过滤,
// 屏幕上的表与导出的文件迟早不一样,而那种不一样没有任何东西会报错 ——
// 进料导出那一份(app/inbound/export/route.ts)早就是这么做的:导出复用列表页
// 自己的过滤模块,所以"当前视图"只有一个定义。这里照抄那条。
import { addDaysIso } from '@/lib/dates'
import { businessToday } from '@/lib/format'


// ── 导出 ─────────────────────────────────────────────────────────────────────
// TABLE-EXPORT-1(Tim 2026-10-22 Q5):四张报表各自那条手写的 CSV 路由(…/export/route.ts)删掉了,
// 由表上的统一导出(Excel / CSV,app/components/ui/table-export.tsx)取代 —— 四页都不分页,
// 表手里已经是全体,所以不需要服务端那一半。csvCell / csvDateTime / csvResponse / exportFailed
// 随之没有调用者,一并删去;下面的 todayStamp 还被 PDF 的文件名用着(pdfShared.tsx),留下。

export function todayStamp(): string {
    const d = new Date()
    const p = (n: number) => String(n).padStart(2, '0')
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`
}


// ── 台账的默认日期窗 ─────────────────────────────────────────────────────────
// 【只有台账需要界】另外三张报表的行数由【当下的库存状态】决定:
// 快照 = 物料 × 库位 × 状态里非零的格子、违规 = 违规的格子、安全库存 = 被监控的
// 物料。它们不随时间增长 —— 今天线上分别是 5 / 0 / 0 行,而一年后仍然只与
// "有多少物料、多少库位"成正比。台账不同:它是 append-only 的流水,只会变长
// (今天 85 行)。所以界加在台账上,另外三张【明写不需要】,与仪表盘那条
// "有界,或写下为什么不需要界"同一条。
export const LEDGER_DEFAULT_DAYS = 90

// TABLE-FEATURES-2(Tim 2026-10-26 Q9):起点 = 新加坡的今天往回 90 天。原来是本机钟 setDate 再 toISOString() 取【UTC】日期,
//   于是在新加坡 00:00–08:00 之间算出的是"UTC 今天 − 90",窗口多出一天。现在只做纯日期算术,不碰时区。
//   (清空起始日仍然回到这个默认 —— windowNote 说的"清空即放宽"做不到,另案登记,本刀不改。)
export function defaultLedgerFrom(): string {
    return addDaysIso(businessToday(), -LEDGER_DEFAULT_DAYS)
}
