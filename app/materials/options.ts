// app/materials/options.ts
// 物料模块共享的下拉选项

export const CATEGORY_OPTIONS = [
    '进料-电池',
    '进料-黑粉',
    '产出-黑粉',
    '产出-金属',
    '产出-其他',
    '耗材辅料',
    '其他',
]

export const CHEMISTRY_OPTIONS = [
    'NMC',
    'NCA',
    'LFP',
    'LCO',
    'LMO',
    'LTO',
    '钠离子',
    '混合',
    '不适用',
    '其他',
]

export const UNIT_OPTIONS = ['kg', '吨', '克', '件']

// 选中此值时,显示自由文本输入框
export const CUSTOM_VALUE = '其他'
