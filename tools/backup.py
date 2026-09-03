#!/usr/bin/env python3
"""
把 Supabase 里的四张表导出成 CSV + JSON。

Supabase 免费版没有自动备份，所有业务数据只存在云端一份。动数据结构或
批量删改之前，先跑一次这个。

凭证：
    脚本从 ~/.supabase-win.env 读取 service_role 密钥，绝不打印、不写日志。
    该文件需要你自己创建，格式：

        SUPABASE_SERVICE_KEY=eyJhbGciOi...

    创建后务必收紧权限：chmod 600 ~/.supabase-win.env

    密钥在 Supabase 控制台 → Project Settings → API → service_role。
    ⚠️ 这个密钥能绕过所有 RLS，等同数据库管理员，绝不能提交到仓库或发给任何人。

输出：
    默认写到 ~/win-backups/YYYY-MM-DD-HHMM/ —— 刻意放在仓库外面。
    仓库是公开的，备份里有采购成本和利润数据，误提交就永久公开了。

用法：
    python3 tools/backup.py                  # 导出到默认目录
    python3 tools/backup.py --out /some/dir  # 指定目录
"""
import argparse
import csv
import datetime
import json
import pathlib
import ssl
import sys
import urllib.error
import urllib.request

PROJECT_URL = "https://heluodmvrwmnwxrtogmc.supabase.co"
TABLES = ["users", "profit_config", "sales_record", "ad_expense"]
CRED_FILE = pathlib.Path.home() / ".supabase-win.env"
PAGE_SIZE = 1000


def ssl_context() -> ssl.SSLContext:
    """
    python.org 版的 macOS Python 不带 CA 根证书，直接请求会
    CERTIFICATE_VERIFY_FAILED。依次尝试 certifi 和 macOS 自带的证书包。
    """
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        pass
    mac_bundle = pathlib.Path("/etc/ssl/cert.pem")
    if mac_bundle.exists():
        return ssl.create_default_context(cafile=str(mac_bundle))
    return ssl.create_default_context()


def load_key() -> str:
    if not CRED_FILE.exists():
        sys.exit(
            f"找不到凭证文件 {CRED_FILE}\n\n"
            "请先创建它（内容一行）：\n"
            "    SUPABASE_SERVICE_KEY=你的service_role密钥\n\n"
            "然后收紧权限：\n"
            f"    chmod 600 {CRED_FILE}\n\n"
            "密钥位置：Supabase 控制台 → Project Settings → API → service_role"
        )
    if CRED_FILE.stat().st_mode & 0o077:
        print(f"⚠️  {CRED_FILE} 权限过宽，建议执行：chmod 600 {CRED_FILE}")
    for line in CRED_FILE.read_text().splitlines():
        line = line.strip()
        if line.startswith("SUPABASE_SERVICE_KEY="):
            key = line.split("=", 1)[1].strip().strip("'\"")
            if key:
                return key
    sys.exit(f"{CRED_FILE} 里没找到 SUPABASE_SERVICE_KEY")


def fetch_table(table: str, key: str, ctx: ssl.SSLContext) -> list:
    """分页拉全表。Supabase REST 单次最多 1000 行。"""
    rows, offset = [], 0
    while True:
        url = f"{PROJECT_URL}/rest/v1/{table}?select=*&limit={PAGE_SIZE}&offset={offset}"
        req = urllib.request.Request(
            url, headers={"apikey": key, "Authorization": f"Bearer {key}"}
        )
        try:
            with urllib.request.urlopen(req, timeout=60, context=ctx) as resp:
                page = json.loads(resp.read())
        except urllib.error.HTTPError as e:
            # 注意：不要把 key 带进报错信息
            sys.exit(f"拉取 {table} 失败：HTTP {e.code} {e.reason}")
        rows.extend(page)
        if len(page) < PAGE_SIZE:
            return rows
        offset += PAGE_SIZE


def write_table(outdir: pathlib.Path, table: str, rows: list) -> None:
    (outdir / f"{table}.json").write_text(
        json.dumps(rows, ensure_ascii=False, indent=1)
    )
    if not rows:
        (outdir / f"{table}.csv").write_text("")
        return
    # 并集取列名，避免某些行缺字段导致列丢失
    cols, seen = [], set()
    for r in rows:
        for c in r:
            if c not in seen:
                seen.add(c)
                cols.append(c)
    with (outdir / f"{table}.csv").open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        w.writerows(rows)


def main() -> None:
    ap = argparse.ArgumentParser()
    default_out = pathlib.Path.home() / "win-backups"
    ap.add_argument("--out", type=pathlib.Path, default=default_out,
                    help=f"备份根目录（默认 {default_out}，刻意放在仓库外）")
    args = ap.parse_args()

    key = load_key()
    ctx = ssl_context()
    stamp = datetime.datetime.now().strftime("%Y-%m-%d-%H%M")
    outdir = args.out / stamp
    outdir.mkdir(parents=True, exist_ok=True)

    print(f"导出到 {outdir}\n")
    summary = {}
    for t in TABLES:
        rows = fetch_table(t, key, ctx)
        write_table(outdir, t, rows)
        summary[t] = len(rows)
        print(f"  {t:<16} {len(rows):>6} 行")

    # 附一份 schema，CSV + schema 才是可还原的备份
    schema = pathlib.Path(__file__).resolve().parent.parent / "db" / "schema.sql"
    if schema.exists():
        (outdir / "schema.sql").write_text(schema.read_text())
        print("\n  schema.sql       已附带")

    (outdir / "manifest.json").write_text(json.dumps({
        "exported_at": datetime.datetime.now().isoformat(timespec="seconds"),
        "project": PROJECT_URL,
        "row_counts": summary,
    }, ensure_ascii=False, indent=1))

    print(f"\n完成，共 {sum(summary.values())} 行")
    if any(v == 0 for v in summary.values()):
        print("⚠️  有表是 0 行 —— 若与预期不符，检查用的是不是 service_role 密钥"
              "（anon 密钥会被 RLS 挡住，返回空）")


if __name__ == "__main__":
    main()
