// 状态机定义(纯数据,无副作用,可以在 Server 和 Client 都用)

// 7 个状态对应的中文标签
export const STATUS_LABELS: Record<string, string> = {
    draft: '草稿',
    pending_review: '待审核',
    approved: '已批准',
    rejected: '已驳回',
    active: '活跃',
    suspended: '已暂停',
    blacklisted: '已拉黑',
    archived: '已归档',
}

// 合法状态流转表(必须跟数据库 trigger 一致)
export const ALLOWED_TRANSITIONS: Record<string, string[]> = {
    draft: ['pending_review', 'archived'],
    pending_review: ['approved', 'rejected', 'draft'],
    rejected: ['draft', 'archived'],
    approved: ['active', 'suspended', 'archived'],
    active: ['suspended', 'blacklisted', 'archived'],
    suspended: ['active', 'blacklisted', 'archived'],
    blacklisted: ['archived'],
    archived: ['draft'],
}

// 每个流转动作的按钮文案
export const TRANSITION_LABELS: Record<string, string> = {
    pending_review: '提交审核',
    approved: '批准',
    rejected: '驳回',
    draft: '退回草稿',
    active: '激活',
    suspended: '暂停',
    blacklisted: '拉黑',
    archived: '归档',
}

// 需要二次确认的"重要"流转
export const DESTRUCTIVE_TRANSITIONS = new Set([
    'blacklisted',
    'archived',
    'rejected',
])