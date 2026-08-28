import { getTranslations } from '@/lib/i18n/server'

// EQP-2d:设备三张表的拒绝 → 人话。
//
// ════════════════════════════════════════════════════════════════════════════
// 【这一支与本仓库其他 *ErrorCodes.ts 【不是同一种东西】,而这正是它存在的理由】
//
// 其余每一支(paymentErrorCodes / expenseErrorCodes / logisticsErrorCodes …)
// 解析的都是 RPC 抛出的【具名业务码】,形如 `CODE|参数0|参数1`。
// **equipment_maintenance / equipment_downtime / equipment_service_intervals
// 三张表没有任何 RPC** —— EQP-2a/2b/2c 都只建了表、视图和臂,写入走 PostgREST
// 直连 + RLS。于是它们的拒绝到达浏览器时是【Postgres 的约束违反】:
//
//     new row for relation "equipment_service_intervals" violates check
//     constraint "equipment_service_intervals_at_least_one"
//     duplicate key value violates unique constraint "uq_equipment_downtime_open"
//
// **一个 `CODE|args` 解析器对着这种消息只会原样吐回去** —— 也就是把一串
// Postgres 的英文机器话打到操作员脸上。所以这一支按【约束名】认,不按码认。
//
// 【为什么不干脆加一组 RPC】那要一支迁移,而本刀是纯渲染;而且 2a/2b/2c 的
// brief 都把"写入走表 + RLS"当成既定形状建的。**改写入路径是一次设计变更,
// 不是一次上屏。** 记在 docs/known-issues.md,带返回条件。
//
// 【本刀是这些拒绝第一次【够得着人】的时刻】在 EQP-2d 之前,库里这十六条
// 约束一条都没有屏幕可以撞上 —— 所以它们此前【一句人话都没有】不是疏漏,
// 是还没到时候。到了。
//
// 【判据:约束名出现在消息里就算命中】不用正则抠位置 —— Postgres 把名字原样
// 印在消息里,而这些名字长得足够特别,不会误伤。命中不了的【原样返回】,
// 与其余各支同一条:一个认不出的错必须看得见,不能被吞成一句通用的"出错了"。
// ════════════════════════════════════════════════════════════════════════════
//
// 【加一条约束 = 来这里加一个名字】check-i18n 的 equipment.errors.* 后缀集合
// 现读下面这个 Set,所以漏了句子 npm run build 当场红。
const EQUIPMENT_ERROR_CODES = new Set([
    // ── 约束名(数据库直接抛)────────────────────────────────────────────────
    // equipment_maintenance(EQP-2b)
    'equipment_maintenance_performer_shape',
    'equipment_maintenance_capitalisation_reason',
    'equipment_maintenance_capitalised_expense',
    'equipment_maintenance_kind_check',
    'equipment_maintenance_description_check',
    // equipment_downtime(EQP-2a)
    'equipment_downtime_period_order',
    'equipment_downtime_reason_stated',
    'uq_equipment_downtime_open',
    // equipment_service_intervals(EQP-2c)
    'equipment_service_intervals_at_least_one',
    'equipment_service_intervals_lead_kg_shape',
    'equipment_service_intervals_lead_days_shape',
    'equipment_service_intervals_one_per_kind',
    'equipment_service_intervals_kind_check',
    'equipment_service_intervals_interval_kg_check',
    'equipment_service_intervals_interval_days_check',
    'equipment_service_intervals_disposition_check',
    // ── FIX-1:一件【发生过】的事不可能在明天发生 ──────────────────────────
    // 这四条是【具名码】,不是约束名 —— 因为它们要把冲突本身写进句子里
    // (撞上的是哪一段停机、你填的是哪一天),而一条 CHECK 的消息带不了这些。
    'DOWNTIME_START_IN_FUTURE',
    'DOWNTIME_END_IN_FUTURE',
    'DOWNTIME_OVERLAPS',
    'ASSET_IN_SERVICE_IN_FUTURE',
    // ── 服务端动作自己抛的具名码 ────────────────────────────────────────────
    // 【日期与描述由动作独立拒空,不只靠表上的 NOT NULL】
    // NOT NULL 违反的消息里【没有约束名】(只有列名),按名认不出来;而这条规矩
    // 本来就要求"提交控件禁用 + 服务端独立拒空"两层(AGENTS.md 那条决定期间的
    // 日期永不默认)。所以动作自己抛具名码,表上那条 NOT NULL 是第三层兜底。
    'MAINT_DATE_REQUIRED',
    'MAINT_DESCRIPTION_REQUIRED',
    'MAINT_PERFORMER_REQUIRED',
    'MAINT_REASON_REQUIRED',
    'DOWNTIME_START_REQUIRED',
    'DOWNTIME_END_REQUIRED',
    'DOWNTIME_REASON_REQUIRED',
    'INTERVAL_NOTHING_STATED',
    // ── record_expense 的两条,资本化那条路【今天走不到】但接好 ──────────────
    // 见 MaintenanceForm 上那句话:投用之后的追加按名拒(record_expense 的判据是
    // in_service_date IS NOT NULL —— 一个【未来】的投用日照样拦,FA-2026-0001
    // 的 2027-01-01 今天就拦得住)。那一刀在队列里;在它落地之前,这两句是
    // 这条路上唯一的人话。
    'ASSET_ALREADY_IN_SERVICE',
    // ── CAPEX-1:给一台在跑的机器资本化后续支出 ─────────────────────────────
    // 【逐条从函数体数出来的】重数一遍(把 CODES 换成下面那几个码的交替式):
    //   grep -rhoE "RAISE EXCEPTION .(CODES)" db/functions/*.sql db/tables/*.sql
    // 【为什么不把那个正则原样写在这里】check-i18n 从这个 Set 的字面量里
    // 数键,而它按【单引号配对】切 —— 注释里一个落单的单引号就会让它把
    // 半条注释读成一个键(实测:构建当场报一串 expense.errors. 的空后缀)。
    // 所以这条命令写成不含引号的形状,而不是删掉它:它是这张表怎么来的唯一出处。
    'ASSET_IN_SERVICE_NEEDS_MAINTENANCE', 'MAINTENANCE_NOT_FOUND',
    'MAINTENANCE_ASSET_MISMATCH', 'MAINTENANCE_NOT_CAPITALISED',
    'MAINTENANCE_ALREADY_CAPITALISED', 'MAINTENANCE_NOT_APPLICABLE',
    'ASSET_LIFE_EXHAUSTED', 'DEPRECIATION_ANCHOR_IMMUTABLE',
    'ASSET_DISPOSED',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeEquipmentError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const t = await getTranslations()

    // ① 约束名:出现在消息里就算命中。**先查这一步** —— Postgres 的约束违反消息
    //    尾巴上常常也有一串大写字母,先跑 CODE_RE 会误判。
    for (const name of EQUIPMENT_ERROR_CODES) {
        if (name === name.toLowerCase() && raw.includes(name)) {
            return t('equipment.errors.' + name)
        }
    }

    // ② 具名码(动作自己抛的,以及 record_expense 那两条)
    const match = raw.match(CODE_RE)
    if (match && EQUIPMENT_ERROR_CODES.has(match[1])) {
        const params: Record<string, string> = {}
        if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
        return t('equipment.errors.' + match[1], params)
    }

    // ③ 认不出的原样返回 —— 一个看不见的错比一个丑陋的错坏得多。
    return raw
}
