// ESG-2(Tim 2026-10-31 Q11 – Q14):举报登记簿的几组取值 → 消息键。
//   【真源在库里】check-i18n 现读每一组的源:状态 = whistleblowing_updates.sql 的 CHECK + whistleblowing_report_rows.sql 里没有状态时的 'received';
//   来源与收到的方式 = whistleblowing_reports.sql 的 CHECK。下面的 as const 只是表单的选项顺序,不是翻译的真源。

/** 读者能追加的状态(与 whistleblowing_updates.status 的 CHECK 同一张清单) */
export const WB_UPDATE_STATUSES = ['acknowledged', 'investigating', 'closed'] as const
/** 外来举报收到的方式(与 whistleblowing_reports.received_via 的 CHECK 同一张清单) */
export const WB_RECEIVED_VIA = ['email', 'letter', 'phone', 'in_person', 'other'] as const

export function wbStatusKey(status: string): string {
    return 'esg.whistleblowing.status.' + status
}
export function wbSourceKey(source: string): string {
    return 'esg.whistleblowing.source.' + source
}
export function wbViaKey(via: string): string {
    return 'esg.whistleblowing.via.' + via
}
