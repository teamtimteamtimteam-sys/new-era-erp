import type { Messages } from '@/lib/i18n/config'

const zh = {
    nav: {
        suppliers: '供应商',
        customers: '客户',
        materials: '物料',
        inbound: '进料',
        output: '产出',
        processing: '加工',
        inventory: '库存',
        logout: '登出',
    },
    home: {
        subtitle: '锂电池回收 ERP 系统',
        sectionMasterData: '主数据',
        sectionOperations: '业务操作',
        sectionReports: '报表',
    },
    common: {
        switchLang: '中',
    },
} as const satisfies Messages

export default zh
