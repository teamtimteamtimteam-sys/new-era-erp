// lib/trail/dict.ts
// AUDIT-TRAIL-1a:把审计记录造句要用的几样东西组装成一份 TrailDict —— 措辞(text.ts)、字段 / 记录类型 / 取值的英文
// (catalogue.generated.ts)、日期格式化(lib/dates.ts)、本位币。lib/trail/render.ts 自己一个 import 都没有(见它的抬头),
// 所以这些经由这里传进去;scripts/check-trail-wording.mjs 用同样的几样东西自己组一份。
import type { TrailDict } from './render'
import { TRAIL_TEXT } from './text'
import { TRAIL_FIELDS, TRAIL_TABLES, TRAIL_ENUMS } from './catalogue.generated'
import { TRAIL_MACHINE_VALUES } from '@/messages/trail-machine-values'
import { formatDate, formatTrailStamp } from '@/lib/dates'

/**
 * 变更记录开始的那一刻 —— 分界线上那句 "Before …" 用它。
 * ★ 与 db/functions/change_log_began_at.sql 必须是同一个时刻;scripts/check-trail-wording.mjs 逐字比对两处。
 */
export const TRAIL_LOG_BEGAN_AT = '2026-09-28 23:58:11.294246+08'

export function trailDict(baseCurrency: string): TrailDict {
    return {
        text: TRAIL_TEXT,
        fields: TRAIL_FIELDS,
        tables: TRAIL_TABLES,
        enums: TRAIL_ENUMS,
        machine: TRAIL_MACHINE_VALUES,
        baseCurrency,
        // 审计记录只说英文(Q7):日期不随界面语言走
        formatDate: (v: string) => formatDate(v, 'en'),
        formatStamp: (v: string) => formatTrailStamp(v),
    }
}
