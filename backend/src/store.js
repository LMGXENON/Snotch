import fs from "node:fs";
import path from "node:path";

const dataFile = path.resolve(process.cwd(), "data/licenses.json");

function ensureDataFile() {
  const dir = path.dirname(dataFile);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  if (!fs.existsSync(dataFile)) {
    fs.writeFileSync(dataFile, JSON.stringify({ licenses: [] }, null, 2), "utf8");
  }
}

function readDB() {
  ensureDataFile();
  const raw = fs.readFileSync(dataFile, "utf8");
  try {
    const parsed = JSON.parse(raw);
    if (!parsed.licenses || !Array.isArray(parsed.licenses)) {
      return { licenses: [] };
    }
    return parsed;
  } catch {
    return { licenses: [] };
  }
}

function writeDB(db) {
  ensureDataFile();
  const tempFile = `${dataFile}.tmp`;
  fs.writeFileSync(tempFile, JSON.stringify(db, null, 2), "utf8");
  fs.renameSync(tempFile, dataFile);
}

export function findLicenseByHash(hash) {
  const db = readDB();
  return db.licenses.find((l) => l.licenseHash === hash) || null;
}

export function findLicense({ licenseHash, licenseKey }) {
  const db = readDB();
  return db.licenses.find((l) => {
    if (licenseHash && l.licenseHash === licenseHash) return true;
    if (licenseKey && l.licenseKey === licenseKey) return true;
    return false;
  }) || null;
}

export function upsertLicense(license) {
  const db = readDB();
  const idx = db.licenses.findIndex((l) => l.licenseHash === license.licenseHash);
  if (idx >= 0) {
    db.licenses[idx] = { ...db.licenses[idx], ...license };
  } else {
    db.licenses.push(license);
  }
  writeDB(db);
}

export function updateLicense(hash, updater) {
  const db = readDB();
  const idx = db.licenses.findIndex((l) => l.licenseHash === hash);
  if (idx < 0) return null;
  db.licenses[idx] = updater(db.licenses[idx]);
  writeDB(db);
  return db.licenses[idx];
}

export function listLicenses() {
  return readDB().licenses;
}
