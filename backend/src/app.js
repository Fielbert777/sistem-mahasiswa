const express = require('express');

const NIM_PATTERN = /^[0-9]{5,15}$/;

function text(value) {
  return typeof value === 'string' ? value.trim() : '';
}

// Validasi input dari client; mengembalikan data yang sudah dibersihkan + daftar error.
function validate(body) {
  const data = {
    nim: text(body.nim),
    nama: text(body.nama),
    jurusan: text(body.jurusan),
    angkatan: Number(body.angkatan),
  };
  const errors = [];
  if (!NIM_PATTERN.test(data.nim)) errors.push('NIM harus 5-15 digit angka');
  if (!data.nama || data.nama.length > 100) errors.push('Nama wajib diisi (maks. 100 karakter)');
  if (!data.jurusan || data.jurusan.length > 100) errors.push('Jurusan wajib diisi (maks. 100 karakter)');
  if (!Number.isInteger(data.angkatan) || data.angkatan < 2000 || data.angkatan > 2100) {
    errors.push('Angkatan harus tahun 2000-2100');
  }
  return { data, errors };
}

function parseId(req) {
  const id = Number(req.params.id);
  return Number.isInteger(id) && id > 0 ? id : null;
}

// Express 4 tidak menangkap error dari async handler, jadi diteruskan manual ke error handler.
const asyncRoute = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

function createApp({ repo, version = 'dev', checkDb = async () => {} }) {
  const app = express();
  app.disable('x-powered-by');
  app.use(express.json({ limit: '10kb' }));

  app.get('/api/health', async (_req, res) => {
    try {
      await checkDb();
      res.json({ status: 'ok', database: 'up', version });
    } catch {
      res.status(503).json({ status: 'error', database: 'down', version });
    }
  });

  app.get('/api/mahasiswa', asyncRoute(async (_req, res) => {
    res.json(await repo.list());
  }));

  app.get('/api/mahasiswa/:id', asyncRoute(async (req, res) => {
    const id = parseId(req);
    if (!id) return res.status(400).json({ error: 'ID tidak valid' });
    const row = await repo.get(id);
    if (!row) return res.status(404).json({ error: 'Mahasiswa tidak ditemukan' });
    res.json(row);
  }));

  app.post('/api/mahasiswa', asyncRoute(async (req, res) => {
    const { data, errors } = validate(req.body || {});
    if (errors.length) return res.status(400).json({ errors });
    res.status(201).json(await repo.create(data));
  }));

  app.put('/api/mahasiswa/:id', asyncRoute(async (req, res) => {
    const id = parseId(req);
    if (!id) return res.status(400).json({ error: 'ID tidak valid' });
    const { data, errors } = validate(req.body || {});
    if (errors.length) return res.status(400).json({ errors });
    const row = await repo.update(id, data);
    if (!row) return res.status(404).json({ error: 'Mahasiswa tidak ditemukan' });
    res.json(row);
  }));

  app.delete('/api/mahasiswa/:id', asyncRoute(async (req, res) => {
    const id = parseId(req);
    if (!id) return res.status(400).json({ error: 'ID tidak valid' });
    if (!(await repo.remove(id))) return res.status(404).json({ error: 'Mahasiswa tidak ditemukan' });
    res.status(204).end();
  }));

  app.use('/api', (_req, res) => res.status(404).json({ error: 'Endpoint tidak ditemukan' }));

  app.use((err, _req, res, _next) => {
    if (err.type === 'entity.parse.failed') return res.status(400).json({ error: 'Body JSON tidak valid' });
    if (err.code === '23505') return res.status(409).json({ error: 'NIM sudah terdaftar' });
    console.error(err);
    res.status(500).json({ error: 'Terjadi kesalahan pada server' });
  });

  return app;
}

module.exports = { createApp, validate };
