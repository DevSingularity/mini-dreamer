// Managed by deploy/setup-vps.sh — pm2 process definitions for the VPS.
// Reloaded with: pm2 startOrReload deploy/ecosystem.config.js --update-env
const path = require('path');

const root = path.resolve(__dirname, '..');

module.exports = {
  apps: [
    {
      name: 'api-server',
      script: 'index.js',
      cwd: path.join(root, 'apps', 'api-server'),
      instances: 1,
      autorestart: true,
      env: { NODE_ENV: 'production' },
    },
    {
      name: 'reverse-proxy',
      script: 'index.js',
      cwd: path.join(root, 'apps', 'reverse-proxy'),
      instances: 1,
      autorestart: true,
      env: { NODE_ENV: 'production' },
    },
    {
      name: 'frontend',
      script: path.join('node_modules', 'next', 'dist', 'bin', 'next'),
      args: 'start -p 3000',
      cwd: path.join(root, 'apps', 'frontend'),
      instances: 1,
      autorestart: true,
      env: { NODE_ENV: 'production', PORT: '3000' },
    },
  ],
};
