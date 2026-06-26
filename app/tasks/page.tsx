// app/tasks/page.tsx
// 任务看板(Kanban)— 服务端取数,客户端拖拽
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import TaskBoard from './TaskBoard'
import { TASK_COLUMNS } from './types'

export default async function TasksPage() {
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
