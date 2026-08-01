// lib/permissions.ts
// 当前登录者的权限码 —— 服务端读取,单次请求内缓存。
//
// 【为什么界面需要知道权限,遮蔽明明已经在数据库里做完了】
// 因为遮蔽的结果是 null,而 null 在这套系统里【本来就有含义】:未分摊、未填、未定价。
// 界面若把两者一律显示成空白,看数的人无从分辨"没有这个数"和"你不能看这个数"。
// 所以取一次权限码,渲染时才能在 null 上做出正确的区分:
//   * 有权限 + null  → 照旧的空白 / 「—」(确实没有这个数)
//   * 无权限 + null  → t('common.restricted')「受限」
//
// 【这不是安全边界】。安全边界在数据库:cut 2b 已经把原始敏感列的 SELECT 收回,
// 遮蔽视图按 has_permission() 置空。这里只负责【把 null 解释对】。
import { cache } from 'react'
import { createClient } from '@/lib/supabase/server'

// ════════════════════════════════════════════════════════════════════════════
// TODO(权限管理界面切次):【只授 edit 不授 view 必须做成不可能】。
//
// cut 2a 的 fixture 量过这个配置错误的真实后果,比"看不见"更糟:
//   * 纯 INSERT       → 通过(WITH CHECK 只查 .edit);
//   * 写进去的行       → 自己读不回来(SELECT 策略查 .view);
//   * INSERT ... RETURNING → 【直接 42501 报错】,因为 RETURNING 要把新行读回来,
//     于是需要 .view —— 而 PostgREST 默认就是带 representation 的。
// 也就是说这个配置不是"少看见几个数",而是【整条写入路径在应用里当场断掉】。
//
// 所以角色编辑界面里:勾 edit 必须自动勾上 view;取消 view 必须一并取消 edit。
// 不要只给一句警告 —— 这不是偏好问题,是坏配置。
// ════════════════════════════════════════════════════════════════════════════

export const DATA_VIEW_PRICES = 'data.view_prices'
export const DATA_VIEW_PAY = 'data.view_pay'
export const DATA_VIEW_IDENTITY = 'data.view_identity'
export const DATA_VIEW_BANKING = 'data.view_banking'
export const ACTION_MANAGE_PERMISSIONS = 'action.manage_permissions'

// React cache():同一次请求内多个组件调用只打一次数据库。
export const getMyPermissions = cache(async (): Promise<string[]> => {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('current_user_permissions')
    if (error || !data) return []
    return data as string[]
})

export async function can(code: string): Promise<boolean> {
    return (await getMyPermissions()).includes(code)
}

// 三个数据权限的便捷读取,页面里读起来比字符串字面量清楚。
export async function canViewPrices(): Promise<boolean> {
    return can(DATA_VIEW_PRICES)
}
export async function canViewPay(): Promise<boolean> {
    return can(DATA_VIEW_PAY)
}
export async function canViewIdentity(): Promise<boolean> {
    return can(DATA_VIEW_IDENTITY)
}
export async function canViewBanking(): Promise<boolean> {
    return can(DATA_VIEW_BANKING)
}
export async function canManagePermissions(): Promise<boolean> {
    return can(ACTION_MANAGE_PERMISSIONS)
}
