import Link from 'next/link'

export default async function Home() {
    return (
        <div className="p-8 max-w-4xl">
            <h1 className="text-2xl font-bold mb-2">SWM-OS</h1>
            <p className="text-gray-600 mb-8">锂电池回收 ERP 系统</p>

            <h2 className="text-lg font-semibold mb-4">主数据</h2>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <Link
                    href="/suppliers"
                    className="border border-gray-300 rounded-lg p-6 hover:bg-gray-50 hover:border-gray-400 transition block"
                >
                    <h3 className="font-semibold text-lg mb-1">供应商</h3>
                    <p className="text-sm text-gray-600">Suppliers — 供应商主数据管理</p>
                </Link>

                <Link
                    href="/customers"
                    className="border border-gray-300 rounded-lg p-6 hover:bg-gray-50 hover:border-gray-400 transition block"
                >
                    <h3 className="font-semibold text-lg mb-1">客户</h3>
                    <p className="text-sm text-gray-600">Customers — 客户主数据管理</p>
                </Link>
            </div>
        </div>
    )
}
