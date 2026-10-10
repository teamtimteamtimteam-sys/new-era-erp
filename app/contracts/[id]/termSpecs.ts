// TERMS-EDIT-1(Tim 2026-09-27):合同的七张条款表 —— 每一张有哪些格、什么类型、取值范围。
//
// ★【一份描述,两处读】★ 详情页按它画表单与表格,server action 按它取字段、先在字段旁边拒一次。
//   范围与取值逐条对着表镜像上的 CHECK(db/tables/contract_*.sql)写,不多一条、不少一条 ——
//   这里拒的是人读得到的那一句;数据库那条 CHECK 仍然是最后的回答(contractErrorCodes.ts 按约束名接)。
// ★【哪张表写得进,不由这里定】★ 写策略是 action.contract_terms,冻结由 APR-8 的守卫定
//   (生效中 / 有在等的申请 / 到期 / 终止 → CONTRACT_TERMS_FROZEN)。这里只描述形状。

export const TERM_TABLES = [
    'grade_specs', 'insurance_obligations', 'volume_commitments',
    'pricing_terms', 'settlement_terms', 'refining_charges', 'penalty_elements',
] as const
export type TermTable = typeof TERM_TABLES[number]

/** 卖方条款(Q6):买方合同上这四段画出来但按不动,并说出理由 */
export const SELL_ONLY: ReadonlySet<TermTable> = new Set(['pricing_terms', 'settlement_terms', 'refining_charges', 'penalty_elements'])

/** 下拉的取值来自哪里:固定取值(i18n 标签)或页面读出来的字典 */
export type OptionSource =
    | { kind: 'enum'; values: readonly string[] }
    // MES-6a-2(MES-6a Step 0 Q27):物质分三份 —— substances(全部:品位规格)· payables(只有按含量计价的金属:计价条款、精炼费)·
    //   penaltyElements(只有惩罚元素:惩罚条款)。库里的守卫(guard_substance_role)对不该来的按名拒;这里只是不把它递给人。
    | { kind: 'dict'; dict: 'substances' | 'payables' | 'penaltyElements' | 'materials' | 'currencies' | 'indices' }

export type FieldSpec = {
    name: string
    type: 'text' | 'number' | 'integer' | 'select' | 'boolean' | 'textarea'
    required?: boolean
    options?: OptionSource
    /** 闭区间;minExclusive = 下界不含(> 而不是 >=) */
    min?: number
    max?: number
    minExclusive?: boolean
    /** 新增时的默认值(表上有 DEFAULT 的那几格) */
    defaultValue?: string
}

export type SectionSpec = {
    table: TermTable
    /** 真表名 */
    dbTable: string
    /** 一份合同恰好一行(结算口径) */
    onePerContract?: boolean
    fields: readonly FieldSpec[]
}

const PARTY = { kind: 'enum', values: ['us', 'counterparty'] } as const
const NOTES: FieldSpec = { name: 'notes', type: 'textarea' }

export const SECTIONS: readonly SectionSpec[] = [
    {
        table: 'grade_specs', dbTable: 'contract_grade_specs',
        fields: [
            { name: 'metal', type: 'select', required: true, options: { kind: 'dict', dict: 'substances' } },
            { name: 'material_id', type: 'select', options: { kind: 'dict', dict: 'materials' } },
            { name: 'min_pct', type: 'number', min: 0, max: 100 },
            { name: 'max_pct', type: 'number', min: 0, max: 100 },
            NOTES,
        ],
    },
    {
        table: 'insurance_obligations', dbTable: 'contract_insurance_obligations',
        fields: [
            { name: 'insured_by', type: 'select', required: true, options: PARTY },
            { name: 'cover_type', type: 'text', required: true },
            { name: 'min_amount', type: 'number', min: 0 },
            { name: 'currency', type: 'select', options: { kind: 'dict', dict: 'currencies' } },
            NOTES,
        ],
    },
    {
        table: 'volume_commitments', dbTable: 'contract_volume_commitments',
        fields: [
            { name: 'committed_by_party', type: 'select', required: true, options: PARTY },
            { name: 'material_id', type: 'select', options: { kind: 'dict', dict: 'materials' } },
            { name: 'quantity', type: 'number', required: true, min: 0, minExclusive: true },
            { name: 'unit', type: 'text', required: true },
            { name: 'period', type: 'select', required: true,
              options: { kind: 'enum', values: ['month', 'quarter', 'year', 'total'] } },
            { name: 'direction', type: 'select', required: true, defaultValue: 'min',
              options: { kind: 'enum', values: ['min', 'max'] } },
            NOTES,
        ],
    },
    {
        table: 'pricing_terms', dbTable: 'contract_pricing_terms',
        fields: [
            { name: 'metal', type: 'select', required: true, options: { kind: 'dict', dict: 'payables' } },
            { name: 'base_event', type: 'select', required: true,
              options: { kind: 'enum', values: ['shipment', 'arrival', 'assay_complete'] } },
            { name: 'qp_months', type: 'integer', required: true, min: 0, max: 12 },
            { name: 'index_code', type: 'select', required: true, options: { kind: 'dict', dict: 'indices' } },
            { name: 'payable_pct', type: 'number', required: true, min: 0, max: 100, minExclusive: true },
            NOTES,
        ],
    },
    {
        table: 'settlement_terms', dbTable: 'contract_settlement_terms', onePerContract: true,
        fields: [
            { name: 'sale_weight_basis', type: 'select', required: true,
              options: { kind: 'enum', values: ['as_received', 'dry'] } },
            { name: 'settling_party', type: 'select', required: true,
              options: { kind: 'enum', values: ['ours', 'counterparty'] } },
            { name: 'splitting_limit_pct', type: 'number', min: 0, max: 100, minExclusive: true },
            { name: 'sample_retention_required', type: 'boolean', required: true },
            { name: 'sample_retention_days', type: 'integer', min: 0, minExclusive: true },
            { name: 'refining_charge_basis', type: 'select', required: true,
              options: { kind: 'enum', values: ['none_agreed', 'per_metal'] } },
            { name: 'penalty_basis', type: 'select', required: true,
              options: { kind: 'enum', values: ['none_agreed', 'per_element'] } },
            // MES-6a-1(2026-10-09,MES-0 Q63 · V14;MES-6a Step 0 Q22):仲裁费怎么分 —— 可空 = Not yet set(没有默认值)。
            //   取值与表上的 CHECK 是同一张清单(contract_settlement_terms.arbitration_fee_rule)。
            { name: 'arbitration_fee_rule', type: 'select',
              options: { kind: 'enum', values: ['loser_pays', 'equal', 'further_from_umpire_pays', 'buyer', 'seller'] } },
            NOTES,
        ],
    },
    {
        table: 'refining_charges', dbTable: 'contract_refining_charges',
        fields: [
            { name: 'metal', type: 'select', required: true, options: { kind: 'dict', dict: 'payables' } },
            { name: 'usd_per_tonne_of_metal', type: 'number', required: true, min: 0 },
            NOTES,
        ],
    },
    {
        table: 'penalty_elements', dbTable: 'contract_penalty_elements',
        fields: [
            { name: 'substance', type: 'select', required: true, options: { kind: 'dict', dict: 'penaltyElements' } },
            { name: 'threshold_pct', type: 'number', required: true, min: 0, max: 100 },
            { name: 'usd_per_tonne_per_pct_over', type: 'number', required: true, min: 0 },
            NOTES,
        ],
    },
]

export function sectionSpec(table: string): SectionSpec | undefined {
    return SECTIONS.find((s) => s.table === table)
}

/** 表头里编辑器改得动的那几格 —— 对手方与买卖方向在建好之后定死(Q5),不在此列 */
export const HEADER_KINDS = ['supply', 'offtake', 'framework', 'service', 'other'] as const
