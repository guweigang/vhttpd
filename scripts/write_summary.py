#!/usr/bin/env python3
import os

summary_content = """# Summary

- [快速开始](快速开始.md)
"""

book_src = os.path.join(os.path.dirname(__file__), '..', 'book-src')
summary_path = os.path.join(book_src, 'SUMMARY.md')

with open(summary_path, 'w', encoding='utf-8', newline='\n') as f:
    f.write(summary_content)

print(f"Wrote SUMMARY.md to {summary_path}")
