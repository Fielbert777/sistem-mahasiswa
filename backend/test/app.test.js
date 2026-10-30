const { describe, test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const { createApp, validate } = require('../src/app');

// Repository palsu di memori agar unit test tidak butuh PostgreSQL.
function memoryRepo() {
  let rows = [];
  let nextId = 1;
  const duplicate = () => Object.assign(new Error('duplicate key'), { code: '23505' });
  return {
    reset() {
      rows = [];
      nextId = 1;
    },
    async list() {
      return rows;
    },
    async get(id) {
      return rows.find((r) => r.id === id) || null;
    },
    async create(data) {
      if (rows.some((r) => r.nim === data.nim)) throw duplicate();
      const row = { id: nextId++, ...data };
      rows.push(row);
      return row;
    },
    async update(id, data) {
      const index = rows.findIndex((r) => r.id === id);
      if (index < 0) return null;
      if (rows.some((r) => r.nim === data.nim && r.id !== id)) throw duplicate();
      rows[index] = { ...rows[index], ...data };
      return rows[index];
    },
    async remove(id) {
      const before = rows.length;
      rows = rows.filter((r) => r.id !== id);
      return rows.length < before;
    },
  };
}

function listen(app) {
  return new Promise((resolve) => {
    const server = app.listen(0, '127.0.0.1', () => {
      resolve({ server, base: `http://127.0.0.1:${server.address().port}` });
    });
  });
}

function call(base, method, path, body) {
  const options = { method, headers: { 'Content-Type': 'application/json' } };
  if (body !== undefined) options.body = typeof body === 'string' ? body : JSON.stringify(body);
  return fetch(base + path, options);
}

const valid = { nim: '2201001', nama: 'Andi Pratama', jurusan: 'Teknik Informatika', angkatan: 2022 };

describe('validate()', () => {
  test('menerima data valid dan merapikan spasi', () => {
    const { data, errors } = validate({ ...valid, nama: '  Andi  ', angkatan: '2022' });
    assert.deepEqual(errors, []);
    assert.equal(data.nama, 'Andi');
    assert.equal(data.angkatan, 2022);
  });

  test('menolak data kosong dengan 4 pesan error', () => {
    assert.equal(validate({}).errors.length, 4);
  });

  test('menolak NIM berisi huruf dan angkatan di luar rentang', () => {
    const { errors } = validate({ ...valid, nim: '22A01', angkatan: 1999 });
    assert.equal(errors.length, 2);
  });
});

describe('REST API /api/mahasiswa', () => {
  const repo = memoryRepo();
  let ctx;

  before(async () => {
    ctx = await listen(createApp({ repo, version: 'test' }));
  });
  after(() => ctx.server.close());
  beforeEach(() => repo.reset());

  test('GET /api/health -> 200 saat database aktif', async () => {
    const res = await call(ctx.base, 'GET', '/api/health');
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { status: 'ok', database: 'up', version: 'test' });
  });

  test('alur CRUD lengkap', async () => {
    let res = await call(ctx.base, 'POST', '/api/mahasiswa', valid);
    assert.equal(res.status, 201);
    const created = await res.json();
    assert.equal(created.id, 1);

    res = await call(ctx.base, 'GET', '/api/mahasiswa');
    assert.equal((await res.json()).length, 1);

    res = await call(ctx.base, 'PUT', '/api/mahasiswa/1', { ...valid, nama: 'Andi P.' });
    assert.equal(res.status, 200);
    assert.equal((await res.json()).nama, 'Andi P.');

    res = await call(ctx.base, 'GET', '/api/mahasiswa/1');
    assert.equal((await res.json()).nama, 'Andi P.');

    res = await call(ctx.base, 'DELETE', '/api/mahasiswa/1');
    assert.equal(res.status, 204);

    res = await call(ctx.base, 'GET', '/api/mahasiswa/1');
    assert.equal(res.status, 404);
  });

  test('POST dengan data tidak valid -> 400 beserta daftar error', async () => {
    const res = await call(ctx.base, 'POST', '/api/mahasiswa', { nim: 'abc' });
    assert.equal(res.status, 400);
    assert.ok((await res.json()).errors.length > 0);
  });

  test('POST NIM duplikat -> 409', async () => {
    await call(ctx.base, 'POST', '/api/mahasiswa', valid);
    const res = await call(ctx.base, 'POST', '/api/mahasiswa', valid);
    assert.equal(res.status, 409);
  });

  test('PUT/DELETE pada ID yang tidak ada -> 404', async () => {
    assert.equal((await call(ctx.base, 'PUT', '/api/mahasiswa/99', valid)).status, 404);
    assert.equal((await call(ctx.base, 'DELETE', '/api/mahasiswa/99')).status, 404);
  });

  test('ID bukan angka positif -> 400', async () => {
    assert.equal((await call(ctx.base, 'GET', '/api/mahasiswa/abc')).status, 400);
    assert.equal((await call(ctx.base, 'DELETE', '/api/mahasiswa/-1')).status, 400);
  });

  test('body JSON rusak -> 400', async () => {
    const res = await call(ctx.base, 'POST', '/api/mahasiswa', '{"nim":');
    assert.equal(res.status, 400);
  });

  test('endpoint tidak dikenal -> 404 JSON', async () => {
    const res = await call(ctx.base, 'GET', '/api/tidak-ada');
    assert.equal(res.status, 404);
    assert.equal((await res.json()).error, 'Endpoint tidak ditemukan');
  });

  test('error tak terduga dari repository -> 500 tanpa membocorkan detail', async (t) => {
    t.mock.method(repo, 'list', async () => {
      throw new Error('koneksi putus');
    });
    t.mock.method(console, 'error', () => {});
    const res = await call(ctx.base, 'GET', '/api/mahasiswa');
    assert.equal(res.status, 500);
    assert.equal((await res.json()).error, 'Terjadi kesalahan pada server');
  });
});

describe('health check saat database mati', () => {
  test('GET /api/health -> 503', async () => {
    const app = createApp({
      repo: memoryRepo(),
      checkDb: async () => {
        throw new Error('db down');
      },
    });
    const { server, base } = await listen(app);
    try {
      const res = await call(base, 'GET', '/api/health');
      assert.equal(res.status, 503);
      assert.equal((await res.json()).database, 'down');
    } finally {
      server.close();
    }
  });
});
