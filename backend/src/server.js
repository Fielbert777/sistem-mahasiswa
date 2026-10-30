const { Pool } = require('pg');
const { createApp } = require('./app');
const { createRepo } = require('./repo');

const PORT = Number(process.env.PORT) || 3000;
const VERSION = process.env.APP_VERSION || 'dev';

const pool = new Pool({
  host: process.env.DB_HOST || 'db',
  port: Number(process.env.DB_PORT) || 5432,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
  max: 10,
});

async function waitForDb(retries = 15) {
  for (let attempt = 1; ; attempt++) {
    try {
      await pool.query('SELECT 1');
      return;
    } catch (err) {
      if (attempt >= retries) throw err;
      console.log(`Menunggu database (${attempt}/${retries}): ${err.message}`);
      await new Promise((resolve) => setTimeout(resolve, 2000));
    }
  }
}

async function main() {
  await waitForDb();
  const app = createApp({
    repo: createRepo(pool),
    version: VERSION,
    checkDb: () => pool.query('SELECT 1'),
  });
  const server = app.listen(PORT, () => console.log(`Backend v${VERSION} berjalan di port ${PORT}`));

  // docker stop mengirim SIGTERM: tutup koneksi HTTP & pool database dengan rapi.
  const shutdown = (signal) => {
    console.log(`${signal} diterima, mematikan server...`);
    server.close(() => pool.end().finally(() => process.exit(0)));
  };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}

main().catch((err) => {
  console.error('Gagal menjalankan backend:', err.message);
  process.exit(1);
});
