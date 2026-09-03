#!/usr/bin/env python3
"""
用假数据把 index.html 跑起来，免登录、不连生产库。

用途：验证 UI 改动。直接打开 index.html 只能看到登录页，登录后又是生产数据，
不方便造边界情况（比如"型号不在配置中"的孤儿记录）。这个脚本把 Supabase
客户端替换成内存桩，其余代码一行不改，所以跑的是真实组件树、真实 CSS、
真实的祖先层级 —— 这点很重要，之前冻结列的 bug 就是因为脱离真实层级
做简化测试而漏掉的。

用法：
    python3 tools/mock-preview.py          # 生成 /tmp/mockapp.html
    python3 tools/mock-preview.py --serve   # 生成并起本地服务

改假数据：编辑下面的 DB 常量。默认已埋了两条 T808 孤儿广告记录，
用来触发"型号不在利润配置中"的警告条。
"""
import argparse
import http.server
import functools
import pathlib
import socketserver
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = pathlib.Path("/tmp/mockapp.html")

MOCK = r"""
// ===== 假 Supabase 客户端：仅用于本地验证，不连任何真实服务 =====
const DB = {
  users: [{id:'u1',email:'me@test.com',name:'__NAME__',role:'__ROLE__',group_name:__GROUP__}],
  profit_config: [
    {id:'c1',asin_country:'B0AAA00001-US',asin:'B0AAA00001',country:'US',product_model:'808',operator_group:'一组',list_price:39.99,discount_rate:0.05,platform_commission_rate:0.15,ad_cost_rate:0,shipping_cost:4.2,storage_cost:0.6,after_sale_rate:0.02,purchase_cost:8.5,freight_cost:2.1},
    {id:'c2',asin_country:'B0AAA00002-US',asin:'B0AAA00002',country:'US',product_model:'318',operator_group:'一组',list_price:29.99,discount_rate:0,platform_commission_rate:0.15,ad_cost_rate:0,shipping_cost:3.8,storage_cost:0.5,after_sale_rate:0.02,purchase_cost:6.2,freight_cost:1.8},
    {id:'c3',asin_country:'B0AAA00003-US',asin:'B0AAA00003',country:'US',product_model:'716',operator_group:'二组',list_price:49.99,discount_rate:0.1,platform_commission_rate:0.15,ad_cost_rate:0,shipping_cost:5.1,storage_cost:0.8,after_sale_rate:0.03,purchase_cost:11,freight_cost:2.6},
  ],
  sales_record: [
    {id:'s1',asin_country:'B0AAA00001-US',asin:'B0AAA00001',country:'US',record_date:latestFullDay(),product_model:'808',sales_volume:80,locked_profit:9.42,asin_profit:753.6},
    {id:'s2',asin_country:'B0AAA00002-US',asin:'B0AAA00002',country:'US',record_date:latestFullDay(),product_model:'318',sales_volume:60,locked_profit:7.11,asin_profit:426.6},
  ],
  model_owner: __OWNERS__,
  ad_expense: [
    {id:'a1',record_date:latestFullDay(),product_model:'808', country:'US',ad_cost:120.5,ad_sales:30,total_sales:80,ld_bd_cost:0,category_rank:1200},
    {id:'a2',record_date:latestFullDay(),product_model:'318', country:'US',ad_cost:88.2, ad_sales:21,total_sales:60,ld_bd_cost:0,category_rank:2400},
    // 故意留两条孤儿记录：型号不在 profit_config 中，用来触发警告条
    {id:'a3',record_date:latestFullDay(),product_model:'T808',country:'US',ad_cost:31.4, ad_sales:8, total_sales:19,ld_bd_cost:2.5,category_rank:3100},
    {id:'a4',record_date:daysAgo(1),      product_model:'T808',country:'US',ad_cost:27.9, ad_sales:6, total_sales:15,ld_bd_cost:0,  category_rank:3300},
  ],
};
// 简易 RLS 模拟。不模拟这一层的话，三种角色看起来一模一样，等于没验证。
//   组长：本组全部    组员：只看指派给自己的型号
function rlsFilter(table, rows){
  const me = DB.users[0];
  if (me.role === 'admin') return rows;
  if (me.role === 'leader'){
    const g = me.group_name;
    const okModels = new Set(DB.profit_config.filter(c=>c.operator_group===g).map(c=>c.product_model));
    const okAsin   = new Set(DB.profit_config.filter(c=>c.operator_group===g).map(c=>c.asin_country));
    if (table==='profit_config') return rows.filter(r=>r.operator_group===g);
    if (table==='ad_expense')    return rows.filter(r=>okModels.has(r.product_model));
    if (table==='sales_record')  return rows.filter(r=>okAsin.has(r.asin_country));
    if (table==='model_owner')   return rows.filter(r=>okModels.has(r.product_model));
    if (table==='users')         return rows.filter(r=>r.group_name===g);
    return rows;
  }
  const mine = new Set(DB.model_owner.filter(o=>o.owner_id===me.id).map(o=>o.product_model));
  const okAsin = new Set(DB.profit_config.filter(c=>mine.has(c.product_model)).map(c=>c.asin_country));
  if (table==='profit_config') return rows.filter(r=>mine.has(r.product_model));
  if (table==='ad_expense')    return rows.filter(r=>mine.has(r.product_model));
  if (table==='sales_record')  return rows.filter(r=>okAsin.has(r.asin_country));
  if (table==='model_owner')   return rows.filter(r=>r.owner_id===me.id);
  return rows;
}

function qb(table){
  let rows=rlsFilter(table,[...(DB[table]||[])]);
  const api={
    select(){return api;}, order(){return api;},
    single(){return Promise.resolve({data:rows[0]||null,error:rows[0]?null:{message:'no row'}});},
    eq(c,v){rows=rows.filter(r=>String(r[c])===String(v));return api;},
    gte(c,v){rows=rows.filter(r=>r[c]>=v);return api;},
    lte(c,v){rows=rows.filter(r=>r[c]<=v);return api;},
    ilike(c,v){const p=String(v).replace(/%/g,'').toLowerCase();rows=rows.filter(r=>String(r[c]).toLowerCase().includes(p));return api;},
    update(){return api;}, insert(){return api;}, upsert(){return api;}, delete(){return api;},
    // fetchAll 靠 range 分页。桩数据量小，一页就取完，但接口必须支持
    range(a,b){rows=rows.slice(a,b+1);return api;},
    then(res){return Promise.resolve({data:rows,error:null}).then(res);}
  };
  return api;
}
sb = {
  from:(t)=>qb(t),
  auth:{
    getSession:()=>Promise.resolve({data:{session:{user:{id:'u1',email:'admin@test.com'}}}}),
    onAuthStateChange:()=>({data:{subscription:{unsubscribe(){}}}}),
    signInWithPassword:()=>Promise.resolve({data:{user:{id:'u1',email:'admin@test.com'}},error:null}),
    signOut:()=>Promise.resolve({}),
  }
};
"""

RENDER = "ReactDOM.createRoot(document.getElementById('root')).render(React.createElement(App));"
REAL_CLIENT = "const sb = createClient(SUPABASE_URL, SUPABASE_KEY);"


def build(role: str, group: str | None, owns: list[str]) -> pathlib.Path:
    src = (ROOT / "index.html").read_text()
    if REAL_CLIENT not in src or RENDER not in src:
        sys.exit("index.html 结构已变，锚点找不到了。检查 REAL_CLIENT / RENDER 两个常量。")
    owners = ",".join(
        "{product_model:'%s',owner_id:'u1'}" % m for m in owns
    )
    names = {"admin": "lintao", "leader": "测试组长", "member": "测试组员"}
    mock = (MOCK
            .replace("__ROLE__", role)
            .replace("__NAME__", names[role])
            .replace("__GROUP__", "null" if group is None else f"'{group}'")
            .replace("__OWNERS__", "[" + owners + "]"))
    out = src.replace(REAL_CLIENT, "let sb;  // 由下方 mock 赋值")
    # mock 必须在 render 之前、helper 之后（它要用 latestFullDay / daysAgo）
    out = out.replace(RENDER, mock + "\n" + RENDER)
    OUT.write_text(out)
    return OUT


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--serve", action="store_true", help="生成后起本地服务")
    ap.add_argument("--port", type=int, default=8781)
    ap.add_argument("--role", choices=["admin", "leader", "member"], default="admin",
                    help="以哪种角色登录（默认 admin）")
    ap.add_argument("--group", default=None,
                    help="leader/member 所属运营组，如 一组。role=admin 时忽略")
    ap.add_argument("--owns", default="",
                    help="member 负责的型号，逗号分隔，如 808,318。留空模拟未被指派")
    args = ap.parse_args()

    group = args.group if args.role != "admin" else None
    if args.role != "admin" and not group:
        group = "一组"
    owns = [m.strip() for m in args.owns.split(",") if m.strip()]
    path = build(args.role, group, owns)
    print(f"已生成 {path}  （角色 {args.role}"
          f"{'/' + group if group else ''}"
          f"{'，负责 ' + ','.join(owns) if owns else ''}）")
    if not args.serve:
        print(f"直接打开：open {path}")
        return

    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(path.parent))
    with socketserver.TCPServer(("", args.port), handler) as httpd:
        print(f"http://localhost:{args.port}/{path.name}   (Ctrl+C 停止)")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n已停止")


if __name__ == "__main__":
    main()
