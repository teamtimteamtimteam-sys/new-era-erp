import type { Database } from '@/lib/database.types'

type Tables = Database['public']['Tables']

// 取某张表的 Insert 类型。code 由 BEFORE INSERT 触发器自动生成，
// 前端插入时用 as 断言成这个类型即可（运行时 code 必被触发器填充）。
export type InsertRow<T extends keyof Tables> = Tables[T]['Insert']
