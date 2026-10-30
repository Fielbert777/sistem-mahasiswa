-- Dijalankan otomatis oleh image postgres saat volume data masih kosong (inisialisasi pertama).
CREATE TABLE IF NOT EXISTS mahasiswa (
    id          SERIAL PRIMARY KEY,
    nim         VARCHAR(15)  NOT NULL UNIQUE,
    nama        VARCHAR(100) NOT NULL,
    jurusan     VARCHAR(100) NOT NULL,
    angkatan    SMALLINT     NOT NULL CHECK (angkatan BETWEEN 2000 AND 2100),
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

INSERT INTO mahasiswa (nim, nama, jurusan, angkatan) VALUES
    ('2201001', 'Andi Pratama',   'Teknik Informatika', 2022),
    ('2201002', 'Siti Rahmawati', 'Sistem Informasi',   2022),
    ('2301015', 'Budi Santoso',   'Teknik Elektro',     2023)
ON CONFLICT (nim) DO NOTHING;
