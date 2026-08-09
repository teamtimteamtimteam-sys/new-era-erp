// app/tasks/page.tsx
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

    if (error) {
        return (
            <div className="p-8">
                <h1 className="mb-4 text-2xl font-bold">{t('tasks.pageTitle')}</h1>
                <div className="rounded border border-red-400 bg-red-100 px-4 py-3 text-red-700">
                    <p className="font-bold">{t('tasks.loadError')}</p>
                    <pre className="mt-2 text-xs">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    return (
        <div className="p-8">
            <h1 className="mb-4 text-2xl font-bold">{t('tasks.pageTitle')}</h1>
            <TaskBoard tasks={tasks ?? []} />
        </div>
    )
}
