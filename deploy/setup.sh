#!/bin/bash
# VPS Setup Script for GATE9 SPORTS
# Run on fresh Ubuntu 22.04+ VPS

set -e

APP_NAME="gate9_sports"
DEPLOY_USER="deploy"
APP_DIR="/var/www/$APP_NAME"

echo "=== Installing dependencies ==="
apt update && apt upgrade -y
apt install -y git curl nginx sqlite3 libsqlite3-dev build-essential libssl-dev libreadline-dev zlib1g-dev

echo "=== Installing rbenv + Ruby ==="
su - $DEPLOY_USER -c "
  git clone https://github.com/rbenv/rbenv.git ~/.rbenv
  echo 'export PATH=\"\$HOME/.rbenv/bin:\$PATH\"' >> ~/.bashrc
  echo 'eval \"\$(rbenv init -)\"' >> ~/.bashrc
  git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build
  ~/.rbenv/bin/rbenv install 3.3.6
  ~/.rbenv/bin/rbenv global 3.3.6
"

echo "=== Setting up app directory ==="
mkdir -p $APP_DIR
chown -R $DEPLOY_USER:$DEPLOY_USER $APP_DIR

echo "=== Nginx config ==="
cp $APP_DIR/deploy/nginx.conf /etc/nginx/sites-available/$APP_NAME
ln -sf /etc/nginx/sites-available/$APP_NAME /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

echo "=== Systemd service ==="
cp $APP_DIR/deploy/$APP_NAME.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable $APP_NAME

echo "=== Cron setup ==="
su - $DEPLOY_USER -c "cd $APP_DIR && bundle exec whenever --update-crontab $APP_NAME"

echo "=== Done! ==="
echo "1. Clone your repo to $APP_DIR"
echo "2. Run: bundle install && rails db:migrate && rails assets:precompile"
echo "3. Start: systemctl start $APP_NAME"
