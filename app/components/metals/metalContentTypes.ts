// app/components/metals/metalContentTypes.ts
// 金属含量(化验)面板的共享类型 + 金属清单的单一来源。
// 进料/产出两侧共用同一面板;这是普通模块(无 'use server'/'use client'),两端都能 import。
//
// updated_at 在服务端按当前语言预格式化成 updated_at_display 再传进来
// —— 与附件面板一致,避免客户端 toLocaleString 造成水合不一致。
export type MetalContentRow = {
    metal: string
    content_pct: number
    updated_at_display: string
}

// 金属清单 / 校验集合 / 反查:复用 metal-prices 模块的定义,不在这里重复金属列表。
export { METAL_OPTIONS, METAL_VALUES, metalLabelKey } from '@/app/metal-prices/options'
