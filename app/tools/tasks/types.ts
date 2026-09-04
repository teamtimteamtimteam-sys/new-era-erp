// app/tools/tasks/types.ts
// 共享类型 / 常量(服务端 actions 与客户端组件都从这里引用,保持一致)
// 注意:这是普通模块,不是 'use server' —— 可以导出类型与常量。

// 卡片 / 编辑表单需要的列(SELECT 与各 action 返回值都用它,保持同步)
export const TASK_COLUMNS =
    'id, code, title, description, status, priority, due_date, reminder_at, tags, task_type'

export type Task = {
    id: string
    code: string
    title: string
    description: string | null
    status: string
    priority: string
    due_date: string | null // 'YYYY-MM-DD'
    reminder_at: string | null // ISO timestamp
    tags: string[] | null
    task_type: string
    // TASK-1b:派生值【只有一处实现】—— task_board_rows。看板与详情页读同一个表达式,
    // 否则两份实现从写下的第二天开始漂移(这个仓库为这件事付过四次学费)。
    //
    // 【可选,因为它们不属于"一行任务",属于"看板上的一行"】新建/保存返回的是
    // tasks 那张表的行,它身上【没有】这三个值 —— 缺席在这里是诚实的。
    // 卡片按"缺席就什么都不显示"处理,而那恰好也是零步骤该有的样子(Q11);
    // revalidatePath 之后服务端重取,值就回来了。
    node_count?: number
    done_count?: number
    steps_overrun_due_date?: boolean | null
}

// 表单提交给 action 的结构化输入
export type TaskInput = {
    title: string
    description: string | null
    status: string
    priority: string
    due_date: string | null // 'YYYY-MM-DD' 或 null
    reminder_at: string | null // ISO 字符串 或 null
    tags: string[]
    task_type: string
}

// 规范的 DB 枚举值(用于遍历下拉项与服务端校验);展示用的标签走 i18n:
// t('tasks.status.' + value) / t('tasks.priority.' + value) / t('tasks.type.' + value)
export const STATUS_VALUES = ['todo', 'in_progress', 'done'] as const
export const PRIORITY_VALUES = ['high', 'medium', 'low'] as const
export const TASK_TYPE_VALUES = ['personal', 'team'] as const

// action 返回结果(判别联合:用 'error' in res 区分)
export type SaveResult = { error: string } | { success: true; task: Task }
export type DeleteResult = { error: string } | { success: true }
