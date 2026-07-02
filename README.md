# zstd_block_compress

Scripts for **Zstandard (zstd) block compression and decompression** of sorted files, enabling efficient line retrieval via an index.

> **⚠️ Important:** Input files **must be sorted** (lexicographically, using `LC_ALL=C`) on the first field (for general files) or the last field of the FASTA header (for FASTA files).

---

## 📦 Compression

Compress a sorted file to create an indexed, queryable archive.

```bash
./frame_compress.sh input_file output_stem
```

This generates two files:

    output_stem.framed.zst – The compressed Zstandard file.
    output_stem.index.tsv – The index file for fast key-based queries.

## 🔓 Decompression

The compressed file is a standard Zstandard archive and can be decompressed using:

```bash
zstd -d compressed_file.framed.zst
```

This restores the original file.
## 🔍 Querying

Retrieve lines (or fasta records) by key using the index:

```bash
./query_zst.sh index.tsv framed_file.zst key
```

Key Behavior:
    For general text files, the key is the first space-separated field.
    For FASTA files, the key is the last field of the FASTA header.

## 📁 File Formats
File Extension	Description
.framed.zst	Compressed Zstandard file with block framing.
.index.tsv	Tab-separated index file mapping keys to byte offsets.

## 📌 Notes

    Ensure input files are sorted before compression.
    The index enables O(log n) lookup time for keys.
