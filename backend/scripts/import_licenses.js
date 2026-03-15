import fs from "node:fs";
import path from "node:path";
import { upsertLicense } from "../src/store.js";

const csvPath = process.argv[2];
if (!csvPath) {
  console.error("Usage: npm run import:licenses -- /absolute/or/relative/path/to/licenses.csv");
  process.exit(1);
}

const resolved = path.resolve(process.cwd(), csvPath);
if (!fs.existsSync(resolved)) {
  console.error("File not found:", resolved);
  process.exit(1);
}

const lines = fs.readFileSync(resolved, "utf8").split(/\r?\n/).filter(Boolean);
const header = lines.shift();
if (!header) {
  console.error("Empty CSV");
  process.exit(1);
}

const columns = header.split(",").map((s) => s.trim());
const idx = {
  licenseHash: columns.indexOf("license_hash"),
  devicesAllowed: columns.indexOf("devices_allowed"),
  status: columns.indexOf("status"),
};

if (idx.licenseHash < 0) {
  console.error("CSV must include license_hash column");
  process.exit(1);
}

let imported = 0;
for (const line of lines) {
  const parts = line.split(",");
  const licenseHash = (parts[idx.licenseHash] || "").trim();
  if (!licenseHash) continue;

  const devicesAllowed = Number((parts[idx.devicesAllowed] || "2").trim()) || 2;
  const status = (parts[idx.status] || "active").trim() || "active";

  upsertLicense({
    licenseHash,
    status,
    devicesAllowed,
    activations: [],
    createdAt: new Date().toISOString(),
  });
  imported += 1;
}

console.log(`Imported ${imported} license hashes`);
