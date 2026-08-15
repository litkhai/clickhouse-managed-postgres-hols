#!/usr/bin/env python3
"""Turn the station spreadsheet into CSV on stdout.

Reads xlsx directly — it is a zip of XML — so the lab needs no pandas, no
openpyxl, nothing but the standard library.

The sheet has a five-row merged header and starts its data at row 6:

    A 대여소번호   B 대여소명   C 자치구   D 상세주소
    E 위도        F 경도      G 설치시기  H 거치대수

Cells are addressed by column letter rather than by position, because empty
cells are simply absent from the XML — counting `<c>` elements would shift
every column after the first gap.
"""
import csv
import html
import re
import sys
import zipfile

COLUMNS = ["A", "B", "C", "D", "E", "F", "H"]
HEADER = ["station_id", "name", "district", "address", "lat", "lon", "racks"]
FIRST_DATA_ROW = 6


def cell_values(row_xml, shared):
    out = {}
    for cell in re.findall(r"<c\b[^>]*>.*?</c>|<c\b[^>]*/>", row_xml, re.S):
        ref = re.search(r'r="([A-Z]+)\d+"', cell)
        val = re.search(r"<v>(.*?)</v>", cell, re.S)
        if not ref or not val:
            continue
        if re.search(r't="s"', cell):
            idx = int(val.group(1))
            text = shared[idx] if idx < len(shared) else ""
        else:
            text = val.group(1)
        # Ten station names and addresses carry line breaks from the sheet.
        # csv would quote them correctly, but a name spanning two lines is
        # awkward everywhere downstream, so collapse whitespace here.
        out[ref.group(1)] = re.sub(r"\s+", " ", text).strip()
    return out


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: xlsx2csv.py <stations.xlsx>")

    book = zipfile.ZipFile(sys.argv[1])
    shared = []
    if "xl/sharedStrings.xml" in book.namelist():
        raw = book.read("xl/sharedStrings.xml").decode("utf-8")
        # One <si> may hold several <t> runs; join them or names split apart.
        for item in re.findall(r"<si>(.*?)</si>", raw, re.S):
            shared.append(html.unescape("".join(re.findall(r"<t[^>]*>(.*?)</t>", item, re.S))))

    sheet = next(n for n in book.namelist() if n.startswith("xl/worksheets/sheet"))
    rows = re.findall(r'<row[^>]*r="(\d+)"[^>]*>(.*?)</row>', book.read(sheet).decode("utf-8"), re.S)

    writer = csv.writer(sys.stdout)
    writer.writerow(HEADER)
    written = skipped = 0
    for number, row_xml in rows:
        if int(number) < FIRST_DATA_ROW:
            continue
        cells = cell_values(row_xml, shared)
        record = [cells.get(c, "") for c in COLUMNS]
        station_id, name, _, _, lat, lon, _ = record
        # A station with no id or no position is useless to a spatial join, and
        # the sheet ends with blank spacer rows. Drop both, and say how many.
        if not station_id.strip().isdigit() or not lat or not lon:
            skipped += 1
            continue
        record[1] = name.strip()
        writer.writerow(record)
        written += 1

    print(f"{written} stations, {skipped} rows skipped", file=sys.stderr)


if __name__ == "__main__":
    main()
