// Lapisan akses data: semua query SQL ada di sini (parameterized, aman dari SQL injection).
const COLUMNS = 'id, nim, nama, jurusan, angkatan, created_at, updated_at';

function createRepo(pool) {
  return {
    async list() {
      const { rows } = await pool.query(`SELECT ${COLUMNS} FROM mahasiswa ORDER BY id`);
      return rows;
    },

    async get(id) {
      const { rows } = await pool.query(`SELECT ${COLUMNS} FROM mahasiswa WHERE id = $1`, [id]);
      return rows[0] || null;
    },

    async create({ nim, nama, jurusan, angkatan }) {
      const { rows } = await pool.query(
        `INSERT INTO mahasiswa (nim, nama, jurusan, angkatan) VALUES ($1, $2, $3, $4) RETURNING ${COLUMNS}`,
        [nim, nama, jurusan, angkatan],
      );
      return rows[0];
    },

    async update(id, { nim, nama, jurusan, angkatan }) {
      const { rows } = await pool.query(
        `UPDATE mahasiswa SET nim = $1, nama = $2, jurusan = $3, angkatan = $4, updated_at = NOW()
         WHERE id = $5 RETURNING ${COLUMNS}`,
        [nim, nama, jurusan, angkatan, id],
      );
      return rows[0] || null;
    },

    async remove(id) {
      const { rowCount } = await pool.query('DELETE FROM mahasiswa WHERE id = $1', [id]);
      return rowCount > 0;
    },
  };
}

module.exports = { createRepo };
