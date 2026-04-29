import assert from "node:assert/strict";
import test from "node:test";
import request from "supertest";

process.env.NODE_ENV = "test";
process.env.OPENAI_API_KEY = process.env.OPENAI_API_KEY || "test-openai-key";
process.env.ADMIN_API_KEY = process.env.ADMIN_API_KEY || "test-admin-key";
process.env.JWT_SECRET = process.env.JWT_SECRET || "test-jwt-secret";
process.env.LICENSE_PEPPER = process.env.LICENSE_PEPPER || "test-license-pepper";

const { app } = await import("../src/server.js");

test("GET /health returns service status", async () => {
  const response = await request(app).get("/health").expect(200);

  assert.equal(response.body.ok, true);
  assert.equal(response.body.service, "snotch-backend");
  assert.equal(typeof response.body.time, "string");
});

test("POST /v1/admin/auth rejects incorrect admin key", async () => {
  const response = await request(app)
    .post("/v1/admin/auth")
    .send({ adminKey: "wrong-key" })
    .expect(401);

  assert.equal(response.body.ok, false);
});

test("GET /v1/admin/licenses requires admin header", async () => {
  const response = await request(app).get("/v1/admin/licenses").expect(401);

  assert.equal(response.body.ok, false);
});

test("POST /v1/generate/script validates topic", async () => {
  const response = await request(app)
    .post("/v1/generate/script")
    .send({ topic: "" })
    .expect(400);

  assert.equal(response.body.ok, false);
});
