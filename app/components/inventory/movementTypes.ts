// app/components/inventory/movementTypes.ts
// 库存流水时间线的共享类型。普通模块(无 'use server'/'use client')。
// occurred_at 在服务端按当前语言预格式化成 occurred_at_display,避免客户端水合不一致。
//
// 【SO-2:删掉了 MOVEMENT_TYPE_VALUES】那个数组声称"与 DB 的 movement_type
// CHECK 集合一致(8 类)",而 DB 早已是 12 类(STK-1 的两条状态腿、IOD-1 的
// 两条转移腿都没加进来),并且【全仓库没有任何地方引用它】。一份没人读、又
// 与真相不符的清单,只会让下一个人相信它是对的 —— 键的检查本来就由
// check-i18n 直接读 db/tables/inventory_movements.sql 的 CHECK 完成
// (scripts/check-i18n.mjs 的 'movements.type.' 那一条),那才是唯一的出处。
export type MovementRow = {
    id: string
    movement_type: string
    qty_delta: number
    business_date: string | null
    notes: string | null
    occurred_at_display: string
    run: { id: string; code: string } | null
    // SO-2:这一行动的是【哪个桶】。此前时间线一个字都不显示它,于是一次暂扣
    // 与一次预留在屏幕上长得一模一样(两行"状态变更(出/进)"),看的人无从
    // 分辨货是被扣住了还是被许出去了 —— 而那正是他打开这张表要问的事。
    stock_status: string
}
