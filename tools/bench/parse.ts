import type { CsvRow } from "./types";

export function parseCsvLine(line: string): CsvRow | null {
  const cols = splitCsv(line);
  if (cols.length < 9) return null;

  const timestamp = Number(cols[0]);
  const iterations = Number(cols[3]);
  const durationMs = Number(cols[4]);
  const opsPerSec = Number(cols[5]);
  if (!Number.isFinite(timestamp) || !Number.isFinite(iterations) || !Number.isFinite(durationMs) || !Number.isFinite(opsPerSec)) {
    return null;
  }

  const row: CsvRow = {
    timestamp,
    featureId: cols[1],
    testName: cols[2],
    iterations,
    durationMs,
    opsPerSec,
    memAllocated: Number(cols[6]) || 0,
    memReserved: Number(cols[7]) || 0,
    memPeak: Number(cols[8]) || 0,
  };

  if (cols.length > 9) {
    row.sampleCount = Number(cols[9]) || 1;
    row.opsP50 = Number(cols[10]);
    row.opsP95 = Number(cols[11]);
    row.opsStddev = Number(cols[14]);
    row.runMode = cols[22];
    row.gitSha = cols[23];
    row.cpuModel = unquoteCsv(cols[24] ?? "");
    row.cpuCores = Number(cols[25]);
    row.osInfo = cols[26];
    row.bunVersion = cols[27];
    row.zigVersion = cols[28];
    row.perfSamples = Number(cols[31]);
  }

  return row;
}

export function parseCsvText(text: string): CsvRow[] {
  const lines = text.split(/\r?\n/).filter(Boolean);
  if (lines.length < 2) return [];
  const rows: CsvRow[] = [];
  for (let i = 1; i < lines.length; i += 1) {
    const row = parseCsvLine(lines[i]);
    if (row) rows.push(row);
  }
  return rows;
}

function splitCsv(line: string): string[] {
  const out: string[] = [];
  let cur = "";
  let inQuotes = false;
  for (let i = 0; i < line.length; i += 1) {
    const ch = line[i];
    if (ch === '"') {
      if (inQuotes && line[i + 1] === '"') {
        cur += '"';
        i += 1;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }
    if (ch === "," && !inQuotes) {
      out.push(cur);
      cur = "";
      continue;
    }
    cur += ch;
  }
  out.push(cur);
  return out;
}

function unquoteCsv(value: string): string {
  if (value.startsWith('"') && value.endsWith('"')) {
    return value.slice(1, -1).replaceAll('""', '"');
  }
  return value;
}