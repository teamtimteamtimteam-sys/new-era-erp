import Link from 'next/link'

const SECTIONS = [
    {
        title: '主数据',
        cards: [
            { href: '/suppliers', title: '供应商', desc: 'Suppliers — 供应商主数据管理' },
            { href: '/customers', title: '客户', desc: 'Customers — 客户主数据管理' },
            { href: '/materials', title: '物料', desc: 'Materials — 物料字典' },
        ],
    },
    {
        title: '业务操作',
        cards: [
            { href: '/inbound', title: '进料批次', desc: 'Inbound — 进料批次台账' },
            { href: '/output', title: '产出批次', desc: 'Output — 产出批次台账' },
            { href: '/processing', title: '加工追溯', desc: 'Processing — 加工单与追溯链' },
        ],
    },
    {
        title: '报表',
        cards: [
            { href: '/inventory', title: '库存与物料平衡', desc: 'Inventory — 库存汇总与物料平衡' },
        ],
    },
]

export default function Home() {
    return (
        <div className="p-8 max-w-4xl">
            <h1 className="text-2xl font-bold mb-2">SWM-OS</h1>
            <p className="text-gray-600 mb-8">锂电池回收 ERP 系统</p>

            {SECTIONS.map((section) => (
                <div key={section.title} className="mb-8">
                    <h2 className="text-lg font-semibold mb-4">{section.title}</h2>
                    <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
                        {section.cards.map((card) => (
                            <Link
                                key={card.href}
                                href={card.href}
                                className="border border-gray-300 rounded-lg p-6 hover:bg-gray-50 hover:border-gray-400 transition block"
                            >
                                <h3 className="font-semibold text-lg mb-1">{card.title}</h3>
                                <p className="text-sm text-gray-600">{card.desc}</p>
                            </Link>
                        ))}
                    </div>
                </div>
            ))}
        </div>
    )
}
