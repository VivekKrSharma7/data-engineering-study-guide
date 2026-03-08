#!/bin/bash
# Merge script for NotebookLM data sources
# Run this after making changes to any .md topic files
# Usage: bash notebookLM/merge.sh (from study-site directory)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SITE_DIR="$(dirname "$SCRIPT_DIR")"
OUT_DIR="$SCRIPT_DIR"

echo "Merging study material for NotebookLM..."
echo "Source: $SITE_DIR"
echo "Output: $OUT_DIR"
echo ""

# 1. SQL Server - all 45 topics + summary
echo "Merging SQL Server..."
echo "# SQL Server - Complete Study Material" > "$OUT_DIR/sql-server-complete.md"
echo "" >> "$OUT_DIR/sql-server-complete.md"
echo "---" >> "$OUT_DIR/sql-server-complete.md"
echo "" >> "$OUT_DIR/sql-server-complete.md"
cat "$SITE_DIR/summary/sql-server-quick-reference.md" >> "$OUT_DIR/sql-server-complete.md"
echo -e "\n\n---\n\n# DETAILED TOPICS\n" >> "$OUT_DIR/sql-server-complete.md"
for f in "$SITE_DIR/sql-server/"[0-9]*.md; do
    echo -e "\n---\n" >> "$OUT_DIR/sql-server-complete.md"
    cat "$f" >> "$OUT_DIR/sql-server-complete.md"
done
echo "  Done: sql-server-complete.md"

# 2. Snowflake - all 50 topics + summary
echo "Merging Snowflake..."
echo "# Snowflake - Complete Study Material" > "$OUT_DIR/snowflake-complete.md"
echo "" >> "$OUT_DIR/snowflake-complete.md"
echo "---" >> "$OUT_DIR/snowflake-complete.md"
echo "" >> "$OUT_DIR/snowflake-complete.md"
cat "$SITE_DIR/summary/snowflake-quick-reference.md" >> "$OUT_DIR/snowflake-complete.md"
echo -e "\n\n---\n\n# DETAILED TOPICS\n" >> "$OUT_DIR/snowflake-complete.md"
for f in "$SITE_DIR/snowflake/"[0-9]*.md; do
    echo -e "\n---\n" >> "$OUT_DIR/snowflake-complete.md"
    cat "$f" >> "$OUT_DIR/snowflake-complete.md"
done
echo "  Done: snowflake-complete.md"

# 3. AI in Data Engineering - all 50 topics + summary
echo "Merging AI in Data Engineering..."
echo "# AI in Data Engineering - Complete Study Material" > "$OUT_DIR/ai-data-engineering-complete.md"
echo "" >> "$OUT_DIR/ai-data-engineering-complete.md"
echo "---" >> "$OUT_DIR/ai-data-engineering-complete.md"
echo "" >> "$OUT_DIR/ai-data-engineering-complete.md"
cat "$SITE_DIR/summary/ai-quick-reference.md" >> "$OUT_DIR/ai-data-engineering-complete.md"
echo -e "\n\n---\n\n# DETAILED TOPICS\n" >> "$OUT_DIR/ai-data-engineering-complete.md"
for f in "$SITE_DIR/ai-data-engineering/"[0-9]*.md; do
    echo -e "\n---\n" >> "$OUT_DIR/ai-data-engineering-complete.md"
    cat "$f" >> "$OUT_DIR/ai-data-engineering-complete.md"
done
echo "  Done: ai-data-engineering-complete.md"

# 4. US Secondary Market - all 50 topics
echo "Merging US Secondary Market..."
echo "# US Secondary Market - Complete Study Material" > "$OUT_DIR/secondary-market-complete.md"
echo "" >> "$OUT_DIR/secondary-market-complete.md"
echo "---" >> "$OUT_DIR/secondary-market-complete.md"
echo "" >> "$OUT_DIR/secondary-market-complete.md"
for f in "$SITE_DIR/secondary-market/"[0-9]*.md; do
    echo -e "\n---\n" >> "$OUT_DIR/secondary-market-complete.md"
    cat "$f" >> "$OUT_DIR/secondary-market-complete.md"
done
echo "  Done: secondary-market-complete.md"

# Print stats
echo ""
echo "=== Merge Complete ==="
for f in "$OUT_DIR/"*-complete.md; do
    lines=$(wc -l < "$f")
    size=$(du -h "$f" | cut -f1)
    name=$(basename "$f")
    echo "  $name: $lines lines ($size)"
done
echo ""
echo "Upload these 4 files to NotebookLM as data sources."
