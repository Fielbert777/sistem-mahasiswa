(function () {
  'use strict';

  // Semua request ke /api/* diteruskan Nginx (container frontend) ke container backend.
  const API = '/api/mahasiswa';
  const $ = (id) => document.getElementById(id);

  const form = $('form-mhs');
  const fields = { id: $('mhs-id'), nim: $('nim'), nama: $('nama'), jurusan: $('jurusan'), angkatan: $('angkatan') };
  const tbody = $('tbody');
  const search = $('search');
  let data = [];
  let toastTimer;

  async function request(url, options = {}) {
    const res = await fetch(url, { headers: { 'Content-Type': 'application/json' }, ...options });
    if (res.status === 204) return null;
    const body = await res.json().catch(() => ({}));
    if (!res.ok) {
      throw new Error(body.errors ? body.errors.join(', ') : body.error || `HTTP ${res.status}`);
    }
    return body;
  }

  function toast(message, isError) {
    const el = $('toast');
    el.textContent = message;
    el.className = isError ? 'toast toast-error' : 'toast';
    el.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { el.hidden = true; }, 3000);
  }

  async function checkHealth() {
    const badge = $('status');
    try {
      const health = await request('/api/health');
      badge.textContent = 'Server & database online';
      badge.className = 'badge badge-ok';
      $('version').textContent = `versi ${health.version}`;
    } catch {
      badge.textContent = 'Server / database offline';
      badge.className = 'badge badge-error';
    }
  }

  function button(label, action, id, extraClass) {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = `btn btn-small ${extraClass || ''}`;
    btn.textContent = label;
    btn.dataset.action = action;
    btn.dataset.id = id;
    return btn;
  }

  function rowElement(m) {
    const tr = document.createElement('tr');
    for (const value of [m.nim, m.nama, m.jurusan, m.angkatan]) {
      const td = document.createElement('td');
      td.textContent = value; // textContent mencegah XSS dari data pengguna
      tr.append(td);
    }
    const actions = document.createElement('td');
    actions.className = 'cell-actions';
    actions.append(button('Edit', 'edit', m.id), button('Hapus', 'delete', m.id, 'btn-danger'));
    tr.append(actions);
    return tr;
  }

  function render() {
    const q = search.value.trim().toLowerCase();
    const rows = data.filter((m) => !q || [m.nim, m.nama, m.jurusan].some((v) => v.toLowerCase().includes(q)));
    tbody.replaceChildren(...rows.map(rowElement));
    $('count').textContent = `(${rows.length})`;
    $('empty').hidden = rows.length > 0;
  }

  async function load() {
    try {
      data = await request(API);
      render();
    } catch (err) {
      toast(`Gagal memuat data: ${err.message}`, true);
    }
  }

  function resetForm() {
    form.reset();
    fields.id.value = '';
    $('form-title').textContent = 'Tambah Mahasiswa';
    $('btn-submit').textContent = 'Simpan';
    $('btn-cancel').hidden = true;
    $('form-error').hidden = true;
  }

  function startEdit(m) {
    fields.id.value = m.id;
    fields.nim.value = m.nim;
    fields.nama.value = m.nama;
    fields.jurusan.value = m.jurusan;
    fields.angkatan.value = m.angkatan;
    $('form-title').textContent = `Edit Mahasiswa: ${m.nama}`;
    $('btn-submit').textContent = 'Perbarui';
    $('btn-cancel').hidden = false;
    fields.nim.focus();
  }

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const id = fields.id.value;
    const payload = {
      nim: fields.nim.value,
      nama: fields.nama.value,
      jurusan: fields.jurusan.value,
      angkatan: Number(fields.angkatan.value),
    };
    try {
      await request(id ? `${API}/${id}` : API, { method: id ? 'PUT' : 'POST', body: JSON.stringify(payload) });
      toast(id ? 'Data berhasil diperbarui' : 'Data berhasil ditambahkan');
      resetForm();
      await load();
    } catch (err) {
      const box = $('form-error');
      box.textContent = err.message;
      box.hidden = false;
    }
  });

  $('btn-cancel').addEventListener('click', resetForm);
  search.addEventListener('input', render);

  tbody.addEventListener('click', async (event) => {
    const btn = event.target.closest('button[data-action]');
    if (!btn) return;
    const m = data.find((item) => String(item.id) === btn.dataset.id);
    if (!m) return;
    if (btn.dataset.action === 'edit') {
      startEdit(m);
    } else if (btn.dataset.action === 'delete' && window.confirm(`Hapus data ${m.nama} (${m.nim})?`)) {
      try {
        await request(`${API}/${m.id}`, { method: 'DELETE' });
        toast('Data berhasil dihapus');
        if (fields.id.value === String(m.id)) resetForm();
        await load();
      } catch (err) {
        toast(`Gagal menghapus: ${err.message}`, true);
      }
    }
  });

  checkHealth();
  load();
  setInterval(checkHealth, 15000);
})();
