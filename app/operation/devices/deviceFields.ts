// app/operation/devices/deviceFields.ts
// MES-1(2026-10-06):设备表单的常量与形状 —— 住在一个【不带 'use client'】的模块里。
// 【为什么不放在 DeviceForm.tsx 里】DeviceForm 是客户端组件;服务端页面从一个 'use client' 文件里 import 的【值】
//   拿到的是一个客户端引用,不是那个数组 —— /operation/devices/[id] 因此 500(「六条条款的键」那个数组的 .map 不是一个函数,
//   MES-1 线上验证量到:冒烟当时线上没有设备、那一条被跳过,版式探针拿探针网关的 id 才撞上)。
//   类型可以照旧从哪里 import 都行;【值】一律从这里拿。
// ⚠ 本抬头里【不写】下面任何一个常量的字面名字:scripts/check-i18n.mjs 的 tsArray 认的是文件里第一次出现的那个名字,
//   写在注释里会让它读错数组(MES-1 实测:把设备种类读成了条款键,i18n 当场红)。
export const DEVICE_KINDS = ['gateway', 'scale', 'weighbridge', 'discharge_cabinet', 'controller', 'meter',
    'workstation', 'scanner', 'inline_instrument', 'alarm_panel'] as const
export const INTERFACE_STATUSES = ['reserved', 'manual_only', 'connected'] as const
export const TERM_KEYS = ['term_protocol', 'term_point_list', 'term_timestamp_precision', 'term_no_charge',
    'term_retention_export', 'term_documentation'] as const
export const TERM_VALUES = ['not_confirmed', 'confirmed', 'not_offered'] as const

export type Option = { id: string; label: string }
export type DeviceValues = {
    name: string; kind: string; gateway_id: string; data_class: string; equipment_id: string; station: string
    capacity: string; resolution: string; unit: string; protection_rating: string; interface_status: string
    heartbeat_interval_s: string; notes: string
} & Record<(typeof TERM_KEYS)[number], string>

export const EMPTY_DEVICE: DeviceValues = {
    name: '', kind: '', gateway_id: '', data_class: '', equipment_id: '', station: '', capacity: '', resolution: '',
    unit: '', protection_rating: '', interface_status: 'reserved', heartbeat_interval_s: '', notes: '',
    term_protocol: 'not_confirmed', term_point_list: 'not_confirmed', term_timestamp_precision: 'not_confirmed',
    term_no_charge: 'not_confirmed', term_retention_export: 'not_confirmed', term_documentation: 'not_confirmed',
}
