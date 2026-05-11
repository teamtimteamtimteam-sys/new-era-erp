import { supabase } from '@/lib/supabase'

export default async function Home() {
  const { data: customers, error } = await supabase
    .from('customers')
    .select('*')
    .order('id', { ascending: true })

  if (error) {
    return (
      <main className="min-h-screen p-8">
        <h1 className="text-2xl font-bold mb-4">客户列表</h1>
        <div className="p-4 bg-red-50 border border-red-200 rounded text-red-700">
          <p className="font-semibold">读取数据失败</p>
          <p className="text-sm mt-1">{error.message}</p>
        </div>
      </main>
    )
  }

  return (
    <main className="min-h-screen p-8 max-w-5xl mx-auto">
      <h1 className="text-2xl font-bold mb-6">客户列表</h1>
      <div className="border rounded-lg overflow-hidden">
        <table className="w-full">
          <thead className="bg-gray-50 border-b">
            <tr>
              <th className="text-left px-4 py-3 text-sm font-medium text-gray-700">ID</th>
              <th className="text-left px-4 py-3 text-sm font-medium text-gray-700">姓名</th>
              <th className="text-left px-4 py-3 text-sm font-medium text-gray-700">邮箱</th>
              <th className="text-left px-4 py-3 text-sm font-medium text-gray-700">电话</th>
              <th className="text-left px-4 py-3 text-sm font-medium text-gray-700">创建时间</th>
            </tr>
          </thead>
          <tbody>
            {customers?.map((c) => (
              <tr key={c.id} className="border-b hover:bg-gray-50">
                <td className="px-4 py-3 text-sm">{c.id}</td>
                <td className="px-4 py-3 text-sm font-medium">{c.name}</td>
                <td className="px-4 py-3 text-sm text-gray-600">{c.email}</td>
                <td className="px-4 py-3 text-sm text-gray-600">{c.phone ?? '—'}</td>
                <td className="px-4 py-3 text-sm text-gray-600">
                  {new Date(c.created_at).toLocaleString('zh-CN')}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="mt-4 text-sm text-gray-500">
        共 {customers?.length ?? 0} 条数据
      </p>
    </main>
  )
}
