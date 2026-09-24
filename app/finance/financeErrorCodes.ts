import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'

// post_journal_entry / reverse_journal_entry / close_period / reopen_period
// 抛出的错误码(端口自 processing/errorCodes.ts)。
// 不在此集合内的,是真正的(未编码的)DB/约束错误,交给共用兜底 lib/machine-text.ts。
const FINANCE_ERROR_CODES = new Set([
    // AP-RECON-1 Batch B:三条日期规矩(Tim AP-RECON-1 Q7)—— 每一条都成句子。
    'POSTING_DATE_BEYOND_CURRENT_MONTH', 'DOCUMENT_DATE_IN_FUTURE', 'REVERSAL_BEFORE_ORIGINAL',
    'JE_NOT_FOUND', 'JE_ALREADY_REVERSED', 'PERIOD_LOCKED',
    // PAY-REQ-1:付款与转账的分录不许从分录页冲 —— 冲付款走冲销申请,冲转账走转账本身。
    'JE_REVERSE_USE_SOURCE_PATH',
    'ACCOUNT_NOT_FOUND', 'ACCOUNT_INACTIVE', 'FX_RATE_REQUIRED',
    'JOURNAL_UNBALANCED',
    'NOT_MONTH_END', 'ALREADY_CLOSED', 'TRIAL_BALANCE_UNBALANCED',
    // ALERT-1(2026-09-08):这四个码 close_period 与 journal 的触发器真的抛得出来,
    // 而它们【不在这个集合里】—— 于是掉进下面那句 `return raw`,屏幕上出现的是
    // DEPRECIATION_OUTSTANDING 这一串大写字母本身。文案见 finance.errors.*。
    'DEPRECIATION_OUTSTANDING', 'PROCESSING_COSTS_UNALLOCATED',
    'JOURNAL_IMMUTABLE', 'JE_LINE_INVALID',
    'CLOSE_NOT_FOUND', 'ALREADY_REOPENED', 'REASON_REQUIRED',
    // FIN-23:年结
    'YEAR_CLOSED', 'YEAR_END_INVALID', 'FINAL_PERIOD_NOT_CLOSED',
    'REVALUATION_NOT_RUN', 'DEPRECIATION_NOT_RUN', 'LATER_YEAR_CLOSED',
    'DATE_REQUIRED', 'SYSTEM_START_NOT_SET',
    // SOD-1:职责分离的两条拒绝。两条都由【触发器】抛出,所以它们会从
    // close_period、/finance/settings 的手动锁、以及 record_payment 三条路上冒出来 ——
    // 一条规矩,两个问法(db/functions/assert_segregated.sql)。
    'SOD_POST_AND_CLOSE', 'SOD_PAYEE_AND_PAY',
    // ROLE-1(Tim 的矩阵,2026-09-23):重开已关的月只归 CFO、只走 reopen_period。
    //   手动锁的直连写若越过一个已关的月,trg_lock_reopen_path 按名拒。
    'REOPEN_THROUGH_CLOSE_ONLY',
    // SOD-1:审批开关的两道闸。前三条管【开】,第四条管【关】(关掉会搁死在途单据),
    // 第五条管【开着的时候不许抽走策略】。
    // ★ APR-1:这一族是从 guard_approvals_switch 的函数体里【逐条枚举】出来的,
    //   不是从"撞到过哪几条"数的。此前这里只有三条真的会出现的码,而那支守卫
    //   抛得出【九条】;另外两条里,APPROVALS_LEVEL2_USER_UNKNOWN 是
    //   CHAIN-BUILD-1 把二级从【人】改成【角色】时就退役了的码 ——
    //   一条已经不存在的拒绝,躺在集合里也躺在两本词典里。已删。
    'APPROVALS_POLICY_INCOMPLETE',
    'APPROVALS_LEVEL1_ROLE_UNHELD', 'APPROVALS_LEVEL2_ROLE_UNHELD',
    'APPROVALS_LEVEL1_HOLDER_CANNOT_SIGN_IN', 'APPROVALS_LEVEL2_HOLDER_CANNOT_SIGN_IN',
    'APPROVALS_LEVEL1_ROLE_CANNOT_SEE_AMOUNTS', 'APPROVALS_LEVEL2_ROLE_CANNOT_SEE_AMOUNTS',
    'APPROVALS_CANNOT_DISABLE_WITH_PENDING',
    'APPROVALS_POLICY_LOCKED_WHILE_ON',
    // APR-1:写闸自己的拒绝,以及单行表那一行不见了的那一条。
    'APPROVALS_POLICY_DIRECT_WRITE', 'APPROVALS_SETTINGS_MISSING',
    // APR-2:开关的第十条具名拒绝 —— 这条链没有人批得动。
    //   它的参数里带一个数字(级别),所以它【依赖 APR-1 那次把码正则的字符类
    //   放宽到含数字的修复】;在那之前它会被截成尾巴一段而到不了屏幕
    //   (APR-1 §3.1 记的九条里六条就是这么丢的)。
    //   ⚠ 本行注释【刻意不写出那个被截出来的字符串】:check-i18n 的 tsSet
    //     把这个 Set 块里【每一对单引号】都当成一个码收走,注释也不例外 ——
    //     第一版写了,于是它当场为一个不存在的码报"缺翻译"。
    //     AGENTS.md「一句注释可以污染将来对它自己的计数」,这是它的第五次。
    'APPROVALS_CHAIN_HAS_NO_APPROVER',
    // GST-1:税码/税率/申报期间的十七条拒绝。**逐条从函数体枚举出来的**,
    // 不是从"撞到过哪几条"数的 —— 它们会从 tax_rate_for、f5_return、
    // f5_box_detail、open_gst_period、file_gst_return、correct_gst_return
    // 以及 gst_return_boxes 的不可变守卫这七处冒出来。
    'GST_NOT_REGISTERED', 'TAX_CODE_REQUIRED', 'TAX_CODE_UNKNOWN', 'TAX_DATE_REQUIRED', 'TAX_RATE_NOT_FOUND',
    // GST-2:税码侧别 / 停用,以及"孰早"那条规矩另一半的按名拒绝。
    'TAX_CODE_INACTIVE', 'TAX_CODE_WRONG_SIDE', 'GST_UNALLOCATED_RECEIPT_UNSUPPORTED',
    // GST-3:注册开关两个方向的闸(trg_gst_switch)。
    'GST_REGISTRATION_NO_REQUIRED',
    'GST_CANNOT_DISABLE_WITH_CODED_EXPENSES', 'GST_CANNOT_DISABLE_WITH_TAXED_INVOICES',
    'GST_PERIOD_DATES_REQUIRED', 'GST_PERIOD_WINDOW_INVALID', 'GST_PERIOD_NOT_A_QUARTER',
    'GST_PERIOD_EXISTS', 'GST_PERIOD_NOT_FOUND', 'GST_PERIOD_ALREADY_FILED',
    'GST_FILED_DATE_REQUIRED', 'GST_PERIOD_NOT_LOCKED',
    'GST_BOX_REQUIRED', 'GST_BOX_NOT_DRILLABLE', 'GST_RETURN_IMMUTABLE',
    'GST_CORRECTION_REASON_REQUIRED', 'GST_CANNOT_CORRECT_UNFILED',
    // AGING-1:账龄的截至日不许落在未来。两侧函数各自独立地抛它 ——
    // 界面上 max=今天 是第一道,这一条是绕开界面也过不去的那一道。
    'AGING_AS_OF_FUTURE',
])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..." —— 即使 PostgREST 在前面包了前缀,
// 也能定位到大写下划线的 code 和它后面 |-分隔的参数。找不到已知 code 就交给共用兜底 lib/machine-text.ts。
// ════════════════════════════════════════════════════════════════════════════
// ★★ APR-1(2026-09-22)· 这个字符类里【没有数字】,而每一条带级别的审批拒绝
//    都带着一个 1 或 2 —— 于是它们【一条都到不了屏幕】。实测,不是推的:
//       'APPROVALS_LEVEL1_ROLE_UNHELD|finance'  →  抓出 '_ROLE_UNHELD'
//       'APPROVALS_LEVEL1_HOLDER_CANNOT_SIGN_IN|finance|1' → '_HOLDER_CANNOT_SIGN_IN'
//    抓出来的那一串谁的集合里都没有,于是走共用兜底 —— 屏幕上说的是
//    「这一步没有发生」,而数据库说的是「一级审批角色的唯一持有人登录不了」。
//    ☞ 一条【写过、翻译过、却永远显示不出来】的句子,比没有那条句子更坏:
//      它让人以为这件事已经被照顾到了。
//    ★ 全库扫过:除审批这一族外,带数字的码【全部】是迁移自证,到不了屏幕。
//      所以本刀只改这两个映射器;其余 44 个同款正则登记在 docs/known-issues.md
//      的 ERRCODE-DIGIT-UNREACHABLE 条,触发条件写在那里。
// ════════════════════════════════════════════════════════════════════════════
const CODE_RE = /([A-Z0-9_]+)(?:\|(.*))?$/

export async function localizeFinanceError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    if (!match || !FINANCE_ERROR_CODES.has(match[1])) {
        return await fallbackForRawError(raw, 'localizeFinanceError@app/finance/financeErrorCodes.ts') // BUGFIX-1b:生码 / 数据库报错 → 一句人话 + 一个可追查的短码(人话句子原样留着)
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v // '0' -> first param, '1' -> second, ...
        })
    }

    return (await getTranslations())('finance.errors.' + code, params)
}
