import { getTranslations } from '@/lib/i18n/server'

// app/tasks/taskErrorCodes.ts
// TASK-1b:任务模块的具名拒绝 → 人话。端口自 deletionErrorCodes.ts。
//
// 【为什么这里还要认【约束名】,而别的模块不用】
// 任务的两条结构规则(一层嵌套、父子同属一张任务)是【约束】,不是触发器 ——
// 那是有意的:一条写不出来的规则强于一条跑起来才生效的规则。代价是它抛出的是
// 23503/23514,而那句话对操作员完全不可读。所以:
//   * 界面【首先】不提供做不到的手势(有子步骤的步骤没有缩进控件,子步骤也没有);
//   * 约束是【兜底】,不是那句话本身 —— 它的原文在这里被翻成一句人话。
// 两层都要有:少了第一层,人会一直撞;少了第二层,撞上的人看到的是 23503。
const TASK_ERROR_CODES = new Set([
    // TASK-1a
    'TASK_PARTICIPANT_NO_LOGIN',
    'TASK_OWNER_CANNOT_LEAVE',
    'TASK_PARTICIPANT_REMOVE_DENIED',
    'TASK_PARTICIPANT_REMOVER_NOT_ON_TASK',
    'TASK_HARD_DELETE_REFUSED',
    'TASK_NODE_HAS_CHILDREN',
    // TASK-1b
    'TASK_OWNER_NOT_AN_EMPLOYEE',
    // TASK-1c-a:建/改任务时归属人解析不出在册员工。守卫抛它,而不是让 NOT NULL 抛 23502。
    'TASK_CREATOR_NOT_AN_EMPLOYEE',
    'TASK_TYPE_LOCKED_PARTICIPANTS',
    'TASK_TYPE_TRANSITION_UNKNOWN',
    // 约束兜底(见文件头)——不是数据库抛的字面量,是本文件按约束名派生的
    'TASK_NODE_SHAPE_REFUSED',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeTaskError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const t = await getTranslations()

    // 一层嵌套 / 跨任务认父:两者撞的是同一条复合外键,再加那条 CHECK。
    // 【合成一句话是对的】:对操作员而言它们是同一件事 ——「这个步骤挂不到那里」。
    if (
        raw.includes('task_nodes_parent_id_task_id_parent_depth_fkey') ||
        (raw.includes('task_nodes') && raw.includes('check'))
    ) {
        return t('tasks.opErrors.TASK_NODE_SHAPE_REFUSED')
    }

    const match = raw.match(CODE_RE)
    if (match && match[1] === 'PERMISSION_DENIED') {
        return t('common.restricted')
    }
    if (!match || !TASK_ERROR_CODES.has(match[1])) {
        return raw
    }
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v
        })
    }
    return t('tasks.opErrors.' + match[1], params)
}
