// app/components/metals/metalContentTypes.ts
// 金属含量(化验)面板的共享类型 + 金属清单的单一来源。
// 进料/产出两侧共用同一面板;这是普通模块(无 'use server'/'use client'),两端都能 import。
//
// updated_at 在服务端按当前语言预格式化成 updated_at_display 再传进来
// —— 与附件面板一致,避免客户端 toLocaleString 造成水合不一致。
//
// PROC-1b:出处列 —— 这一行含量【是谁说的】。三种状态必须看得见(化验 / 手工 /
// 出处未知),它们正是 PROC-1 买来的东西:看产出批的人要分得出哪些数出自实验室。
// 标签在服务端按语言预格式化(同 updated_at_display 的理由);化验来源附上
// 单据链接。两个字段都可省 —— 面板只在有任何一行带出处时才画这一列。
export type MetalContentRow = {
    metal: string
    content_pct: number
    updated_at_display: string
    source_kind?: 'assay' | 'manual' | 'unknown'
    source_label?: string
    source_href?: string | null
}

// PROC-4:这里曾经转出 METAL_OPTIONS / METAL_VALUES / metalLabelKey ——
// 那份清单没了,值与名字都来自 substances 那张字典,由页面读好按 props 传进面板。
export type { MetalOption } from '@/app/metal-prices/options'
