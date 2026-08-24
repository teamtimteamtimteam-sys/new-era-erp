'use client'

// app/login/ClearRestrictedDrafts.tsx
// 受限表单的草稿【不活过一次登出】—— 这里是那句话的落实点。
//
// 【为什么是登录页】这套系统里每一条结束会话的路都落在 /login:空闲超时的重定向、
// 手动登出、会话被吊销。所以在这里清一次,就覆盖了全部三条。而如果人干脆把
// 标签页关掉,sessionStorage 本来就跟着没了 —— 两条路合起来是完整的。
//
// 【它只清受限的那一半】不受限的草稿存在 localStorage 里,活过登出正是它的用途
// (那是"救回工作"那一半)。清掉它们等于把这一刀的一半功能删掉。
import { useEffect } from 'react'
import { clearRestrictedDrafts } from '@/lib/useFormDraft'

export default function ClearRestrictedDrafts() {
    useEffect(() => { clearRestrictedDrafts() }, [])
    return null
}
