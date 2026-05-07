const express = require('express');
const path = require('path');
require('dotenv').config();

const app = express();

const PORT = process.env.FRONTEND_PORT || 8000;
const HOST = process.env.FRONTEND_HOST || '0.0.0.0';
const API = process.env.API || 'http://localhost:3000';

app.get('/config.js', (req, res) => {
  res.type('application/javascript');
  res.send(`window.API = "${API}";`);
});

app.use(express.static(__dirname));

app.listen(PORT, HOST, () => {
  console.log(`Frontend running on http://${HOST}:${PORT}`);
  console.log(`Public API: ${API}`);
});