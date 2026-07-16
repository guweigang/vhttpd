#!/usr/bin/env python3
import os
from pathlib import Path

def main():
    repo_root = Path(__file__).parent.parent
    book_src = repo_root / "book-src"

    lines = ["# Summary", ""]

    # 先列出 index.md
    lines.append("- [Home](index.md)")
    lines.append("")

    # 顶层 .md 文件
    top_level_md = sorted([p for p in book_src.glob("*.md") if p.name not in ("SUMMARY.md", "index.md")])
    for md_path in top_level_md:
        name = md_path.stem
        lines.append(f"- [{name}]({md_path.name})")

    lines.append("")

    # 子目录
    subdirs = sorted([p for p in book_src.iterdir() if p.is_dir() and not p.name.startswith('.')])
    for subdir in subdirs:
        index_md = subdir / f"{subdir.name}.md"
        if index_md.exists():
            lines.append(f"- [{subdir.name}]({subdir.name}/{subdir.name}.md)")
        else:
            first_md = next(subdir.glob("*.md"), None)
            if first_md:
                lines.append(f"- [{subdir.name}]({subdir.name}/{first_md.name})")

    summary_content = "\n".join(lines) + "\n"
    summary_path = book_src / "SUMMARY.md"

    with open(summary_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(summary_content)

    print(f"Generated SUMMARY.md at {summary_path}")

if __name__ == "__main__":
    main()
