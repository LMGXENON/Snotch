import crypto from "node:crypto";

function makeSecret(bytes = 32) {
  return crypto.randomBytes(bytes).toString("hex");
}

console.log("JWT_SECRET=" + makeSecret(32));
console.log("LICENSE_PEPPER=" + makeSecret(32));
console.log("ADMIN_API_KEY=adm_" + makeSecret(24));
