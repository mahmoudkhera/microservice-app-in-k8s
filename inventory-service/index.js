const express = require('express');
const { Pool } = require('pg');

// --- Config from environment ---
const PORT = process.env.PORT || 3001;
const HOST = process.env.HOST || '0.0.0.0';  // ← NEW
const DATABASE_URL = process.env.DATABASE_URL;
const CORS_ORIGIN = process.env.CORS_ORIGIN || '*';
const NOTIFICATION_URL = process.env.NOTIFICATION_URL || 'http://notification:3002/notify';
const ALERT_RECIPIENT = process.env.ALERT_RECIPIENT || 'admin@stockwatch.io';

if (!DATABASE_URL) {
  console.error('❌ DATABASE_URL env var is required');
  process.exit(1);
}

const app = express();
app.use(express.json());

// CORS
app.use((req, res, next) => {
  res.header('Access-Control-Allow-Origin', CORS_ORIGIN);
  res.header('Access-Control-Allow-Methods', 'GET, POST, PATCH, DELETE');
  res.header('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') return res.sendStatus(200);
  next();
});

// --- Postgres connection pool ---
const pool = new Pool({ connectionString: DATABASE_URL });

// Test connection + create schema on startup (with retry for Postgres warmup)
async function initDb(retries = 10) {
  for (let i = 0; i < retries; i++) {
    try {
      await pool.query('SELECT 1');
      console.log('✓ Connected to Postgres successfully');
      break;
    } catch (err) {
      console.log(`Waiting for Postgres... (${i + 1}/${retries})`);
      await new Promise(r => setTimeout(r, 2000));
      if (i === retries - 1) throw err;
    }
  }

  await pool.query(`
    CREATE TABLE IF NOT EXISTS products (
      id SERIAL PRIMARY KEY,
      name TEXT NOT NULL,
      quantity INTEGER NOT NULL,
      threshold INTEGER NOT NULL DEFAULT 5
    );
    CREATE TABLE IF NOT EXISTS alerts (
      id SERIAL PRIMARY KEY,
      product_name TEXT NOT NULL,
      quantity INTEGER NOT NULL,
      threshold INTEGER NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    CREATE TABLE IF NOT EXISTS config (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
  `);

  // Insert default email if not set
  await pool.query(`
    INSERT INTO config (key, value) VALUES ('alert_email', $1)
    ON CONFLICT (key) DO NOTHING
  `, [ALERT_RECIPIENT]);

  console.log('✓ Schema ready');
}

// --- Helpers ---
async function getAlertEmail() {
  const { rows } = await pool.query("SELECT value FROM config WHERE key = 'alert_email'");
  return rows[0]?.value || ALERT_RECIPIENT;
}

async function sendLowStockAlert(product) {
  const email = await getAlertEmail();

  await pool.query(
    'INSERT INTO alerts (product_name, quantity, threshold) VALUES ($1, $2, $3)',
    [product.name, product.quantity, product.threshold]
  );

  try {
    await fetch(NOTIFICATION_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        to: email,
        subject: `⚠️ Low stock: ${product.name}`,
        message: `"${product.name}" is at ${product.quantity} units (threshold: ${product.threshold}).`
      })
    });
    console.log(`Alert sent: ${product.name}`);
  } catch (err) {
    console.error('Notification service unreachable:', err.message);
  }
}

// --- Product CRUD ---
app.get('/products', async (req, res) => {
  const { rows } = await pool.query('SELECT * FROM products ORDER BY id');
  res.json(rows);
});

app.post('/products', async (req, res) => {
  const { name, quantity, threshold } = req.body;
  const { rows } = await pool.query(
    'INSERT INTO products (name, quantity, threshold) VALUES ($1, $2, $3) RETURNING *',
    [name, quantity, threshold || 5]
  );
  res.json(rows[0]);
});

app.patch('/products/:id', async (req, res) => {
  const { quantity } = req.body;
  const id = +req.params.id;
  const { rows } = await pool.query(
    'UPDATE products SET quantity = $1 WHERE id = $2 RETURNING *',
    [quantity, id]
  );
  if (!rows[0]) return res.status(404).json({ error: 'Not found' });
  const product = rows[0];
  if (product.quantity <= product.threshold) sendLowStockAlert(product);
  res.json(product);
});

app.delete('/products/:id', async (req, res) => {
  await pool.query('DELETE FROM products WHERE id = $1', [+req.params.id]);
  res.json({ deleted: true });
});

// --- Manual stock check ---
app.post('/stock-check', async (req, res) => {
  const { rows: low } = await pool.query('SELECT * FROM products WHERE quantity <= threshold');
  for (const p of low) await sendLowStockAlert(p);
  const { rows: total } = await pool.query('SELECT COUNT(*)::int AS c FROM products');
  res.json({ checked: total[0].c, alerted: low.length });
});

// --- Alerts ---
app.get('/alerts', async (req, res) => {
  const { rows } = await pool.query('SELECT * FROM alerts ORDER BY id DESC LIMIT 20');
  res.json(rows);
});

app.delete('/alerts', async (req, res) => {
  await pool.query('DELETE FROM alerts');
  res.json({ cleared: true });
});

// --- Config ---
app.get('/config/email', async (req, res) => {
  res.json({ email: await getAlertEmail() });
});

app.post('/config/email', async (req, res) => {
  await pool.query(
    "UPDATE config SET value = $1 WHERE key = 'alert_email'",
    [req.body.email]
  );
  res.json({ email: req.body.email });
});

app.get('/health', (req, res) => res.json({ status: 'ok', service: 'inventory' }));

// --- Boot ---
initDb().then(() => {
  app.listen(PORT, HOST, () => {
    console.log(`Inventory service on http://${HOST}:${PORT}`);
    console.log(`trigger test2 commit `);
    
  });
}).catch(err => {
  console.error('Failed to initialize DB:', err);
  process.exit(1);
});