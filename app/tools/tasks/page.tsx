// app/tools/tasks/page.tsx
// 任务看板(Kanban)— 服务端取数,客户端拖拽
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import TaskBoard from './TaskBoard'
import { TASK_COLUMNS } from './types'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function TasksPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.tasks)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const { data: tasks, error } = await supabase
        .from('tasks')
        .select(TASK_COLUMNS)
        .is('deleted_at', null)
        .order('created_at', { ascending: false })

    // TASK-1b:步骤数 / 已完成数 / 「步骤排到了截止日之后」——【一律来自视图】,
    // 页面不自己算。两次查询而不是一次,只是因为看板还要 description 之类
    // 视图不吐的列;算法仍然只有 task_board_rows 那一处。
    const { data: derived, error: derivedError } = await supabase
        .from('task_board_rows')
        .select('id, node_count, done_count, steps_overrun_due_date')

    if (error || derivedError) {
        return (
            <div className="p-8">
                <h1 className="mb-4 text-2xl font-bold">{t('tasks.pageTitle')}</h1>
                <div className="rounded border border-red-400 bg-red-100 px-4 py-3 text-red-700">
                    <p className="font-bold">{t('tasks.loadError')}</p>
                    <pre className="mt-2 text-xs">{JSON.stringify(error ?? derivedError, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const byId = new Map((derived ?? []).map((d) => [d.id, d]))
    const merged = (tasks ?? []).map((row) => {
        const d = byId.get(row.id)
        return {
            ...row,
            node_count: d?.node_count ?? 0,
            done_count: d?.done_count ?? 0,
            steps_overrun_due_date: d?.steps_overrun_due_date ?? null,
        }
    })

    return (
        <div className="p-8">
            <h1 className="mb-4 text-2xl font-bold">{t('tasks.pageTitle')}</h1>
            <TaskBoard tasks={merged} />
        </div>
    )
}
