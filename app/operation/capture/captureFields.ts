// app/operation/capture/captureFields.ts
// MES-2(2026-10-06):确认队列、地磅单与校准页共用的常量与类型 —— 一个【不带 'use client'】的普通模块。
// 【为什么单独一个文件】MES-1 实测过:服务端页面从一个 'use client' 文件 import 一个【值】,过界之后拿到的是一个客户端引用,
//   不是那个数组(/operation/devices/[id] 当场 500)。所以页面与客户端控件要共用的值都住在这里。
// 【注意】下面那个读数状态数组的名字只在它的定义处出现一次 —— check-i18n 的 tsArray 认的是文件里第一次出现的那个名字,注释也算
//   (docs/known-issues.md 的 MES1-I18N-TSARRAY-READS-FIRST-MENTION)。
import type { Json } from '@/lib/database.types'

/** 一次读数在它那一刻的校准状态:weighing_calibration_all.status 的全部取值(calibration_status_from 的四种 + not_recorded)。 */
export const CALIBRATION_STATUSES = ['in_calibration', 'expired', 'failed', 'never_calibrated', 'not_recorded'] as const
export type CalibrationStatus = (typeof CALIBRATION_STATUSES)[number]

/** 校准规则管得到的仪器种类(MES-2 Step 0 Q23)—— 与 record_instrument_calibration / instrument_calibration_now 同一组。 */
export const INSTRUMENT_KINDS = ['scale', 'weighbridge', 'meter', 'inline_instrument'] as const

export type Option = { id: string; label: string }

/** 一张还开着的地磅单(只有第一磅)—— 确认 / 手工录入时可以选它来完成。 */
export type OpenTicket = { id: string; code: string; direction: string; vehicle_reg: string }

/** 主语:单独一次净重 · 用这一磅开一张地磅单 · 用这一磅完成一张开着的单。 */
export type Subject =
    | { kind: 'none' }
    | { kind: 'new'; direction: 'inbound' | 'outbound'; vehicleReg: string; notes?: string }
    | { kind: 'ticket'; ticketId: string }

/** 主语 → capture_confirm_internal 认的那一份 jsonb。 */
export function subjectJson(s: Subject): Json {
    if (s.kind === 'new') return { new_ticket: { direction: s.direction, vehicle_reg: s.vehicleReg, notes: s.notes ?? null } }
    if (s.kind === 'ticket') return { ticket_id: s.ticketId }
    return {}
}

/** 一个读数字段:正数(公斤),否则 null。 */
export function positiveKg(raw: string): number | null {
    const s = raw.trim()
    if (s === '') return null
    const n = Number(s)
    return Number.isFinite(n) && n > 0 ? n : null
}
