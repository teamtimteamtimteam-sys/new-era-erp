// messages/trail-machine-values.ts
// AUDIT-TRAIL-1a(Tim 的 Q8):数据里【机器写的中文】→ 审计记录上说的英文。
//   人敲的字(理由、备注、名字)原样印;系统自己写进库里的中文取值,在审计记录上说英文 —— 那是系统的话,不是人的话。
//   目前只有 inbound_batches.stage 这一列(commit_processing_run / rollback_processing_run_internal 写它)。
//   自动审批那一句中文说明(approval_log.note,decision = auto_approved)不经这里:lib/trail/render.ts 按 decision 直接换成
//   'po.autoApproved' 那一句;出库批次的状态走字典(output_batch_states.name_en),也不经这里。
// 【为什么住在 messages/ 下】它是一份翻译表(中文取值 → 英文),与 en.ts / zh.ts 同类;scripts/check-cjk-rendered.mjs
//   不扫 messages/,正是因为这里的中文是【被翻译的对象】,不是上屏的硬串。它不是 i18n 的键表,check-i18n 不读它。
// 【一个 import 都没有】scripts/check-trail-wording.mjs 用 Node 的 type-stripping 直接 import 它。
// 键:'表#列'(与 lib/trail/catalogue.generated.ts 的 TRAIL_ENUMS 同一种写法)。
export const TRAIL_MACHINE_VALUES: Record<string, Record<string, string>> = {
    'inbound_batches#stage': {
        '待加工': 'Awaiting processing',
        '加工中': 'Processing started',
        '已加工完': 'Fully processed',
    },
    // AUDIT-TRAIL-1b-3:物料的单位 —— 下拉框把选项的值存成中文(app/materials/options.ts 的 UNIT_OPTIONS),
    //   页面上照 units.* 说英文;审计记录同一套说法。数量后面的单位(lib/trail/render.ts 的 unitText)也查这里。
    'materials#unit': {
        'kg': 'kg',
        '吨': 't',
        '克': 'g',
        '件': 'pcs',
    },
}
