import "dotenv/config";
import crypto from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import express from "express";
import cors from "cors";
import helmet from "helmet";
import rateLimit from "express-rate-limit";
import jwt from "jsonwebtoken";
import { findLicense, updateLicense, listLicenses, upsertLicense } from "./store.js";

const app = express();
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const PORT = Number(process.env.PORT || 8787);
const OPENAI_API_KEY = process.env.OPENAI_API_KEY || "";
const OPENAI_MODEL = process.env.OPENAI_MODEL || "gpt-4.1-mini";
const JWT_SECRET = process.env.JWT_SECRET || "";
const LICENSE_PEPPER = process.env.LICENSE_PEPPER || "";
const TOKEN_TTL_HOURS = Number(process.env.TOKEN_TTL_HOURS || 72);
const ADMIN_API_KEY = process.env.ADMIN_API_KEY || "";
const ADMIN_BYPASS_UNLIMITED = String(process.env.ADMIN_BYPASS_UNLIMITED || "true").toLowerCase() === "true";

if (!JWT_SECRET || !LICENSE_PEPPER) {
  console.warn("WARNING: JWT_SECRET or LICENSE_PEPPER missing. Set them in environment.");
}

app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      baseUri: ["'self'"],
      fontSrc: ["'self'", "https:", "data:"],
      formAction: ["'self'"],
      frameAncestors: ["'self'"],
      imgSrc: ["'self'", "data:"],
      objectSrc: ["'none'"],
      scriptSrc: ["'self'", "'unsafe-inline'"],
      scriptSrcAttr: ["'none'"],
      styleSrc: ["'self'", "https:", "'unsafe-inline'"],
      connectSrc: ["'self'"],
      upgradeInsecureRequests: null,
    },
  },
}));
app.use(cors());
app.use(express.json({ limit: "1mb" }));
app.use(express.static(path.resolve(__dirname, "../public")));

function isAdminRequest(req) {
  if (!ADMIN_API_KEY) return false;
  const key = req.headers["x-admin-key"];
  return typeof key === "string" && key === ADMIN_API_KEY;
}

app.use((req, _res, next) => {
  req.isAdmin = isAdminRequest(req);
  next();
});

const activationLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 20,
  standardHeaders: true,
  legacyHeaders: false,
  skip: (req) => ADMIN_BYPASS_UNLIMITED && req.isAdmin,
});

const validateLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 60,
  standardHeaders: true,
  legacyHeaders: false,
  skip: (req) => ADMIN_BYPASS_UNLIMITED && req.isAdmin,
});

const generateLimiter = rateLimit({
  windowMs: 60 * 60 * 1000,
  max: 120,
  standardHeaders: true,
  legacyHeaders: false,
  skip: (req) => ADMIN_BYPASS_UNLIMITED && req.isAdmin,
});

function hashLicenseKey(key) {
  return crypto
    .createHmac("sha256", LICENSE_PEPPER || "CHANGE_ME")
    .update(key)
    .digest("hex");
}

function issueToken(payload) {
  return jwt.sign(payload, JWT_SECRET || "CHANGE_ME", {
    expiresIn: `${TOKEN_TTL_HOURS}h`,
  });
}

function verifyToken(token) {
  return jwt.verify(token, JWT_SECRET || "CHANGE_ME");
}

function nowISO() {
  return new Date().toISOString();
}

function addHours(hours) {
  return new Date(Date.now() + hours * 3600 * 1000).toISOString();
}

function requireAuth(req, res, next) {
  if (req.isAdmin && ADMIN_BYPASS_UNLIMITED) {
    req.license = {
      admin: true,
      role: "admin",
      deviceId: req.headers["x-device-id"] || "admin-device",
    };
    return next();
  }

  const auth = req.headers.authorization || "";
  if (!auth.startsWith("Bearer ")) {
    return res.status(401).json({ ok: false, message: "Missing bearer token" });
  }

  try {
    const token = auth.slice("Bearer ".length);
    const payload = verifyToken(token);
    req.license = payload;
    return next();
  } catch {
    return res.status(401).json({ ok: false, message: "Invalid token" });
  }
}

function requireAdmin(req, res, next) {
  if (!req.isAdmin) {
    return res.status(401).json({ ok: false, message: "Unauthorized" });
  }
  return next();
}

function randomKeyBlock(len = 4) {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  let out = "";
  for (let i = 0; i < len; i += 1) {
    out += alphabet[Math.floor(Math.random() * alphabet.length)];
  }
  return out;
}

function normalizePrefix(prefix = "SNTCH") {
  return String(prefix)
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, "")
    .slice(0, 10) || "SNTCH";
}

function makeLicenseKey(prefix = "SNTCH") {
  const p = normalizePrefix(prefix);
  return `${p}-${randomKeyBlock(4)}-${randomKeyBlock(4)}-${randomKeyBlock(4)}`;
}

app.get("/health", (_req, res) => {
  res.json({ ok: true, service: "snotch-backend", time: nowISO() });
});

app.get("/admin", (_req, res) => {
  res.sendFile(path.resolve(__dirname, "../public/admin.html"));
});

app.post("/v1/admin/auth", validateLimiter, (req, res) => {
  const adminKey = String(req.body?.adminKey || "").trim();
  if (!ADMIN_API_KEY) {
    return res.status(500).json({ ok: false, message: "Admin key is not configured on server" });
  }
  if (!adminKey || adminKey !== ADMIN_API_KEY) {
    return res.status(401).json({ ok: false, message: "Invalid admin key" });
  }
  return res.json({ ok: true, message: "Admin authenticated" });
});

app.post("/v1/license/activate", activationLimiter, (req, res) => {
  const { licenseKey, deviceId, deviceName, appVersion, platform } = req.body || {};
  if (!licenseKey || !deviceId || !appVersion || !platform) {
    return res.status(400).json({ ok: false, message: "Missing required fields" });
  }

  const normalizedLicenseKey = String(licenseKey).trim();
  const licenseHash = hashLicenseKey(normalizedLicenseKey);
  const license = findLicense({ licenseHash, licenseKey: normalizedLicenseKey });
  if (!license || license.status !== "active") {
    if (req.isAdmin && ADMIN_BYPASS_UNLIMITED) {
      const token = issueToken({
        licenseHash: "admin",
        deviceId,
        appVersion,
        platform,
        admin: true,
        role: "admin",
      });

      return res.json({
        ok: true,
        token,
        expiresAt: addHours(TOKEN_TTL_HOURS),
        devicesAllowed: 999999,
        message: "Admin activation",
      });
    }
    return res.status(403).json({ ok: false, message: "License not valid" });
  }

  const activations = Array.isArray(license.activations) ? license.activations : [];
  const existing = activations.find((a) => a.deviceId === deviceId);

  if (!existing && activations.length >= (license.devicesAllowed || 2)) {
    return res.status(403).json({ ok: false, message: "Device limit reached" });
  }

  const nextActivations = existing
    ? activations.map((a) =>
        a.deviceId === deviceId
          ? {
              ...a,
              deviceName: deviceName ? String(deviceName).trim().slice(0, 120) : (a.deviceName || ""),
              lastSeenAt: nowISO(),
              appVersion,
              platform,
            }
          : a
      )
    : [
        ...activations,
        {
          deviceId,
          deviceName: deviceName ? String(deviceName).trim().slice(0, 120) : "",
          firstSeenAt: nowISO(),
          lastSeenAt: nowISO(),
          appVersion,
          platform,
        },
      ];

  updateLicense(licenseHash, (prev) => ({ ...prev, activations: nextActivations }));

  const token = issueToken({
    licenseHash,
    deviceId,
    appVersion,
    platform,
  });

  return res.json({
    ok: true,
    token,
    expiresAt: addHours(TOKEN_TTL_HOURS),
    devicesAllowed: license.devicesAllowed || 2,
    message: "Activated",
  });
});

app.post("/v1/license/validate", validateLimiter, (req, res) => {
  const { token, licenseKey, deviceId, deviceName, appVersion, platform } = req.body || {};
  if (!token || !licenseKey || !deviceId || !appVersion || !platform) {
    return res.status(400).json({ ok: false, message: "Missing required fields" });
  }

  if (req.isAdmin && ADMIN_BYPASS_UNLIMITED) {
    return res.json({ ok: true, expiresAt: addHours(TOKEN_TTL_HOURS), message: "Admin valid" });
  }

  let payload;
  try {
    payload = verifyToken(token);
  } catch {
    return res.status(401).json({ ok: false, message: "Token expired or invalid" });
  }

  const normalizedLicenseKey = String(licenseKey).trim();
  const licenseHash = hashLicenseKey(normalizedLicenseKey);
  if (payload.licenseHash !== licenseHash || payload.deviceId !== deviceId) {
    return res.status(403).json({ ok: false, message: "Token mismatch" });
  }

  const license = findLicense({ licenseHash, licenseKey: normalizedLicenseKey });
  if (!license || license.status !== "active") {
    return res.status(403).json({ ok: false, message: "License invalid" });
  }

  const activations = Array.isArray(license.activations) ? license.activations : [];
  const hasDevice = activations.some((a) => a.deviceId === deviceId);
  if (!hasDevice) {
    return res.status(403).json({ ok: false, message: "Device not activated" });
  }

  updateLicense(licenseHash, (prev) => ({
    ...prev,
    activations: prev.activations.map((a) =>
      a.deviceId === deviceId
        ? {
            ...a,
            deviceName: deviceName ? String(deviceName).trim().slice(0, 120) : (a.deviceName || ""),
            lastSeenAt: nowISO(),
            appVersion,
            platform,
          }
        : a
    ),
  }));

  return res.json({
    ok: true,
    expiresAt: addHours(TOKEN_TTL_HOURS),
    message: "Valid",
  });
});

app.post("/v1/generate/script", generateLimiter, requireAuth, async (req, res) => {
  if (!OPENAI_API_KEY) {
    return res.status(500).json({ ok: false, message: "Backend OpenAI key not configured" });
  }

  const {
    topic,
    audience = "General audience",
    tone = "Conversational",
    goal = "Educate",
    styleProfile = "",
    targetMinutes = null,
    useCues = false,
    promptOverride = "",
  } = req.body || {};

  if (!topic || String(topic).trim().length < 2) {
    return res.status(400).json({ ok: false, message: "Topic is required" });
  }

  const lengthRule =
    targetMinutes && Number(targetMinutes) > 0
      ? `Target duration is about ${Number(targetMinutes).toFixed(1)} minutes.`
      : "No strict duration target.";

  const cueRule = useCues
    ? "You may use <focus>, <break>, and <hold 1.2s> when useful."
    : "Do not include cue tags.";

  const styleRule = styleProfile && String(styleProfile).trim().length > 0
    ? `Match this speaking style naturally:\n${String(styleProfile).trim()}`
    : "No extra style profile provided.";

  const userPrompt = String(promptOverride).trim().length > 0
    ? String(promptOverride).trim()
    : [
        `Topic: ${topic}`,
        `Audience: ${audience}`,
        `Tone: ${tone}`,
        `Goal: ${goal}`,
        lengthRule,
        styleRule,
        cueRule,
        "Output only spoken script text.",
        "No markdown. No bullets. No meta labels.",
        "Use original wording and natural human cadence.",
      ].join("\n\n");

  try {
    const response = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${OPENAI_API_KEY}`,
      },
      body: JSON.stringify({
        model: OPENAI_MODEL,
        temperature: 0.75,
        top_p: 0.95,
        max_tokens: 1800,
        messages: [
          {
            role: "system",
            content: "You are an expert video speechwriter. Return only final script text.",
          },
          {
            role: "user",
            content: userPrompt,
          },
        ],
      }),
    });

    const data = await response.json();

    if (!response.ok) {
      const msg = data?.error?.message || "OpenAI request failed";
      return res.status(response.status).json({ ok: false, message: msg });
    }

    const script = data?.choices?.[0]?.message?.content?.trim();
    if (!script) {
      return res.status(500).json({ ok: false, message: "Empty script response" });
    }

    return res.json({ ok: true, script });
  } catch (error) {
    return res.status(500).json({ ok: false, message: `Generation error: ${error.message}` });
  }
});

app.post("/v1/generate/bundles", generateLimiter, requireAuth, async (req, res) => {
  if (!OPENAI_API_KEY) {
    return res.status(500).json({ ok: false, message: "Backend OpenAI key not configured" });
  }

  const { topic, audience = "General audience" } = req.body || {};
  if (!topic || String(topic).trim().length < 2) {
    return res.status(400).json({ ok: false, message: "Topic is required" });
  }

  const prompt = `
Topic: ${topic}
Audience: ${audience}

Return JSON with exactly these keys:
- titles: array of 5 concise video title options
- hooks: array of 5 opening hooks
- ctas: array of 5 call-to-action lines
No markdown.
`;

  try {
    const response = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${OPENAI_API_KEY}`,
      },
      body: JSON.stringify({
        model: OPENAI_MODEL,
        temperature: 0.8,
        max_tokens: 1000,
        response_format: { type: "json_object" },
        messages: [
          { role: "system", content: "You output strict JSON only." },
          { role: "user", content: prompt },
        ],
      }),
    });

    const data = await response.json();
    if (!response.ok) {
      const msg = data?.error?.message || "Bundle generation failed";
      return res.status(response.status).json({ ok: false, message: msg });
    }

    const raw = data?.choices?.[0]?.message?.content || "{}";
    const parsed = JSON.parse(raw);
    return res.json({ ok: true, ...parsed });
  } catch (error) {
    return res.status(500).json({ ok: false, message: `Bundle error: ${error.message}` });
  }
});

app.get("/v1/admin/licenses", requireAdmin, (req, res) => {
  const status = String(req.query.status || "").trim().toLowerCase();
  const q = String(req.query.q || "").trim().toLowerCase();
  const raw = listLicenses();
  const filtered = raw.filter((l) => {
    if (status && String(l.status || "").toLowerCase() !== status) return false;
    if (q) {
      const haystack = [l.licenseKey, l.licenseHash, l.note, l.status]
        .map((v) => String(v || "").toLowerCase())
        .join(" ");
      if (!haystack.includes(q)) return false;
    }
    return true;
  });

  return res.json({
    ok: true,
    count: filtered.length,
    licenses: filtered,
  });
});

app.post("/v1/admin/licenses/create", validateLimiter, requireAdmin, (req, res) => {
  const {
    prefix = "SNTCH",
    licenseKey = "",
    devicesAllowed = 2,
    note = "",
  } = req.body || {};

  const normalizedDevices = Math.max(1, Math.min(999999, Number(devicesAllowed) || 2));
  const normalizedNote = String(note || "").trim().slice(0, 300);

  let finalKey = String(licenseKey || "").trim().toUpperCase();
  if (!finalKey) {
    let attempt = 0;
    while (attempt < 25) {
      const candidate = makeLicenseKey(prefix);
      if (!findLicense({ licenseKey: candidate })) {
        finalKey = candidate;
        break;
      }
      attempt += 1;
    }
    if (!finalKey) {
      return res.status(500).json({ ok: false, message: "Unable to allocate unique license key" });
    }
  } else if (findLicense({ licenseKey: finalKey })) {
    return res.status(409).json({ ok: false, message: "License key already exists" });
  }

  const licenseHash = hashLicenseKey(finalKey);
  const now = nowISO();
  const license = {
    licenseKey: finalKey,
    licenseHash,
    status: "active",
    devicesAllowed: normalizedDevices,
    activations: [],
    createdAt: now,
    updatedAt: now,
    note: normalizedNote,
  };

  upsertLicense(license);
  return res.json({ ok: true, message: "License created", license });
});

app.post("/v1/admin/licenses/revoke", validateLimiter, requireAdmin, (req, res) => {
  const { licenseKey = "", licenseHash = "", reason = "" } = req.body || {};
  const found = findLicense({
    licenseKey: String(licenseKey || "").trim().toUpperCase(),
    licenseHash: String(licenseHash || "").trim(),
  });
  if (!found) {
    return res.status(404).json({ ok: false, message: "License not found" });
  }

  const updated = updateLicense(found.licenseHash, (prev) => ({
    ...prev,
    status: "revoked",
    revokedAt: nowISO(),
    revokeReason: String(reason || "").trim().slice(0, 300),
    updatedAt: nowISO(),
  }));

  return res.json({ ok: true, message: "License revoked", license: updated });
});

app.post("/v1/admin/licenses/reactivate", validateLimiter, requireAdmin, (req, res) => {
  const { licenseKey = "", licenseHash = "" } = req.body || {};
  const found = findLicense({
    licenseKey: String(licenseKey || "").trim().toUpperCase(),
    licenseHash: String(licenseHash || "").trim(),
  });
  if (!found) {
    return res.status(404).json({ ok: false, message: "License not found" });
  }

  const updated = updateLicense(found.licenseHash, (prev) => {
    const next = {
      ...prev,
      status: "active",
      updatedAt: nowISO(),
    };
    delete next.revokedAt;
    delete next.revokeReason;
    return next;
  });

  return res.json({ ok: true, message: "License reactivated", license: updated });
});

app.post("/v1/admin/licenses/update", validateLimiter, requireAdmin, (req, res) => {
  const { licenseKey = "", licenseHash = "", devicesAllowed, note } = req.body || {};
  const found = findLicense({
    licenseKey: String(licenseKey || "").trim().toUpperCase(),
    licenseHash: String(licenseHash || "").trim(),
  });
  if (!found) {
    return res.status(404).json({ ok: false, message: "License not found" });
  }

  const updated = updateLicense(found.licenseHash, (prev) => ({
    ...prev,
    devicesAllowed: devicesAllowed == null
      ? prev.devicesAllowed
      : Math.max(1, Math.min(999999, Number(devicesAllowed) || prev.devicesAllowed || 2)),
    note: note == null ? prev.note : String(note).trim().slice(0, 300),
    updatedAt: nowISO(),
  }));

  return res.json({ ok: true, message: "License updated", license: updated });
});

app.listen(PORT, () => {
  console.log(`Snotch backend running on http://localhost:${PORT}`);
});
