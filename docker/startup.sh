#!/bin/bash

# Cribbed from nextcloud docker official repo
# https://github.com/nextcloud/docker/blob/master/docker-entrypoint.sh
# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
    local var="$1"
    local fileVar="${var}_FILE"
    local def="${2:-}"
    local varValue=$(env | grep -E "^${var}=" | sed -E -e "s/^${var}=//")
    local fileVarValue=$(env | grep -E "^${fileVar}=" | sed -E -e "s/^${fileVar}=//")
    if [ -n "${varValue}" ] && [ -n "${fileVarValue}" ]; then
        echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
        exit 1
    fi
    if [ -n "${varValue}" ]; then
        export "$var"="${varValue}"
    elif [ -n "${fileVarValue}" ]; then
        export "$var"="$(cat "${fileVarValue}")"
    elif [ -n "${def}" ]; then
        export "$var"="$def"
    fi
    unset "$fileVar"
}

# Add docker secrets support for the variables below:
file_env APP_KEY
file_env DB_HOST
file_env DB_PORT
file_env DB_DATABASE
file_env DB_USERNAME
file_env DB_PASSWORD
file_env REDIS_HOST
file_env REDIS_PASSWORD
file_env REDIS_PORT
file_env MAIL_HOST
file_env MAIL_PORT
file_env MAIL_USERNAME
file_env MAIL_PASSWORD

# fix key if needed
if [ -z "$APP_KEY" -a -z "$APP_KEY_FILE" ]
then
  # AUTO-GENERATE: generate APP_KEY and persist in /var/lib/snipeit/keys/.env
  # so restarts reuse the same key (ponytail: per-deploy ephemeral is fine for free tier).
  mkdir -p /var/lib/snipeit/keys
  if [ -f /var/lib/snipeit/keys/.env ]; then
    set -a; . /var/lib/snipeit/keys/.env; set +a
  fi
  if [ -z "$APP_KEY" ]; then
    GENERATED_KEY=$(php artisan key:generate --force --show 2>/dev/null | tail -1)
    if [ -z "$GENERATED_KEY" ]; then
      GENERATED_KEY="base64:$(head -c 32 /dev/urandom | base64)"
    fi
    echo "APP_KEY=$GENERATED_KEY" > /var/lib/snipeit/keys/.env
    export APP_KEY="$GENERATED_KEY"
    echo "[startup] auto-generated APP_KEY"
  fi
fi

if [ -f /var/lib/snipeit/ssl/snipeit-ssl.crt -a -f /var/lib/snipeit/ssl/snipeit-ssl.key ]
then
  a2enmod ssl
else
  a2dismod ssl
fi

# create data directories
# Note: Keep in sync with expected directories by the app
# https://github.com/grokability/snipe-it/blob/master/app/Console/Commands/RestoreFromBackup.php#L232
for dir in \
  'data/private_uploads' \
  'data/private_uploads/assets' \
  'data/private_uploads/accessories' \
  'data/private_uploads/audits' \
  'data/private_uploads/components' \
  'data/private_uploads/consumables' \
  'data/private_uploads/eula-pdfs' \
  'data/private_uploads/imports' \
  'data/private_uploads/models' \
  'data/private_uploads/users' \
  'data/private_uploads/licenses' \
  'data/private_uploads/signatures' \
  'data/uploads/accessories' \
  'data/uploads/assets' \
  'data/uploads/avatars' \
  'data/uploads/barcodes' \
  'data/uploads/categories' \
  'data/uploads/companies' \
  'data/uploads/components' \
  'data/uploads/consumables' \
  'data/uploads/departments' \
  'data/uploads/locations' \
  'data/uploads/maintenances' \
  'data/uploads/manufacturers' \
  'data/uploads/models' \
  'data/uploads/suppliers' \
  'dumps' \
  'keys'
do
  [ ! -d "/var/lib/snipeit/$dir" ] && mkdir -p "/var/lib/snipeit/$dir"
done

chown -R docker:root /var/lib/snipeit/data/*
chown -R docker:root /var/lib/snipeit/dumps
chown -R docker:root /var/lib/snipeit/keys
chown -R docker:root /var/www/html/storage/framework/cache

# AUTO: detect missing DB_HOST (no Postgres available) and force SQLite early.
# Must run BEFORE `php artisan migrate` so Laravel picks up the right driver.
# Also write a minimal .env so Laravel sees our DB_DATABASE (otherwise it falls
# back to /var/www/html/database/database.sqlite which doesn't exist).
if [ -z "$DB_HOST" ] && [ "$DB_CONNECTION" != "sqlite" ]; then
  echo "[startup] no DB_HOST set — forcing sqlite (Render free tier fallback)"
  export DB_CONNECTION=sqlite
  export SESSION_DRIVER=file
  export CACHE_STORE=file
fi
if [ "$DB_CONNECTION" = "sqlite" ]; then
  export DB_DATABASE=/var/lib/snipeit/snipeit.sqlite
  mkdir -p "$(dirname "$DB_DATABASE")"
  touch "$DB_DATABASE"
  chown docker:root "$DB_DATABASE" 2>/dev/null || true
  echo "[startup] sqlite at $DB_DATABASE"
fi

# AUTO: write a minimal .env so Laravel picks up our env. Always overwrite
# the image's default docker.env (which assumes mysql + linked container).
ENV_FILE=/var/www/html/.env
echo "[startup] writing .env (overrides image default docker.env)"
cat > "$ENV_FILE" <<EOF
APP_ENV=${APP_ENV:-production}
APP_DEBUG=${APP_DEBUG:-false}
APP_URL=${APP_URL:-https://iam-tfba.onrender.com}
APP_KEY=${APP_KEY:-}
APP_TIMEZONE=${APP_TIMEZONE:-UTC}
APP_LOCALE=${APP_LOCALE:-en}
LOG_CHANNEL=${LOG_CHANNEL:-stderr}
DB_CONNECTION=${DB_CONNECTION:-sqlite}
DB_DATABASE=${DB_DATABASE:-/var/lib/snipeit/snipeit.sqlite}
DB_HOST=
DB_PORT=
DB_USERNAME=
DB_PASSWORD=
FILESYSTEM_DISK=${FILESYSTEM_DISK:-local}
SESSION_DRIVER=${SESSION_DRIVER:-file}
CACHE_STORE=${CACHE_STORE:-file}
QUEUE_CONNECTION=${QUEUE_CONNECTION:-sync}
MAIL_MAILER=${MAIL_MAILER:-log}
EOF
chown docker:root "$ENV_FILE"

# AUTO: default seed admin credentials if SEED vars not set (Render free tier)
SEED_ADMIN_EMAIL="${SEED_ADMIN_EMAIL:-admin@kirsnickk.local}"
SEED_ADMIN_PASSWORD="${SEED_ADMIN_PASSWORD:-$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)}"
# Persist so restarts reuse
mkdir -p /var/lib/snipeit/keys
echo "SEED_ADMIN_PASSWORD=$SEED_ADMIN_PASSWORD" >> /var/lib/snipeit/keys/.env 2>/dev/null || true
export SEED_ADMIN_EMAIL SEED_ADMIN_PASSWORD
echo "[startup] seed admin: $SEED_ADMIN_EMAIL / (in /var/lib/snipeit/keys/.env)"

# Fix php settings
if [ -v "PHP_UPLOAD_LIMIT" ]
then
    find /etc/php -type f -name php.ini | while IFS= read -r ini; do
        echo "Changing upload limit to ${PHP_UPLOAD_LIMIT}M in $ini"
        sed -i \
            -e "s/^;\? *upload_max_filesize *=.*/upload_max_filesize = ${PHP_UPLOAD_LIMIT}M/" \
            -e "s/^;\? *post_max_size *=.*/post_max_size = ${PHP_UPLOAD_LIMIT}M/" \
            "$ini"
    done
fi

# Fix Apache request header limits
# (defaults live in /etc/apache2/conf-available/limits.conf; override here)
if [ -v "APACHE_LIMIT_REQUEST_FIELD_SIZE" ]
then
    echo "Changing LimitRequestFieldSize to ${APACHE_LIMIT_REQUEST_FIELD_SIZE}"
    sed -i "s/^LimitRequestFieldSize.*/LimitRequestFieldSize ${APACHE_LIMIT_REQUEST_FIELD_SIZE}/" /etc/apache2/conf-available/limits.conf
fi

if [ -v "APACHE_LIMIT_REQUEST_LINE" ]
then
    echo "Changing LimitRequestLine to ${APACHE_LIMIT_REQUEST_LINE}"
    sed -i "s/^LimitRequestLine.*/LimitRequestLine ${APACHE_LIMIT_REQUEST_LINE}/" /etc/apache2/conf-available/limits.conf
fi

if [ -v "APACHE_LIMIT_REQUEST_FIELDS" ]
then
    echo "Changing LimitRequestFields to ${APACHE_LIMIT_REQUEST_FIELDS}"
    sed -i "s/^LimitRequestFields.*/LimitRequestFields ${APACHE_LIMIT_REQUEST_FIELDS}/" /etc/apache2/conf-available/limits.conf
fi

# If the Oauth DB files are not present copy the vendor files over to the db migrations
if [ ! -f "/var/www/html/database/migrations/*create_oauth*" ]
then
  cp -ax /var/www/html/vendor/laravel/passport/database/migrations/* /var/www/html/database/migrations/
fi

if [ "$SESSION_DRIVER" = "database" ]
then
  cp -ax /var/www/html/vendor/laravel/framework/src/Illuminate/Session/Console/stubs/database.stub /var/www/html/database/migrations/2021_05_06_0000_create_sessions_table.php
fi

php artisan migrate --force
php artisan config:clear
php artisan config:cache
php artisan view:clear

# AUTO: storage symlink for public file access
if [ ! -L /var/www/html/public/storage ]; then
  php artisan storage:link 2>&1 | tail -2 || true
fi

# AUTO: seed first admin user if SEED_ADMIN_EMAIL + SEED_ADMIN_PASSWORD are set
# and no admin exists yet. Used by Render deploy — credentials live in /var/lib/snipeit/keys/.env
if [ -n "$SEED_ADMIN_EMAIL" ] && [ -n "$SEED_ADMIN_PASSWORD" ]; then
  EXISTING=$(php artisan tinker --execute='echo \App\Models\User::where("permissions","superuser")->count();' 2>/dev/null | tr -d '[:space:]')
  if [ "$EXISTING" = "0" ] || [ -z "$EXISTING" ]; then
    echo "[startup] seeding first admin $SEED_ADMIN_EMAIL"
    php artisan tinker --execute="
      \$u = new \App\Models\User();
      \$u->first_name = 'Admin';
      \$u->last_name = 'User';
      \$u->username = 'admin';
      \$u->email = '$SEED_ADMIN_EMAIL';
      \$u->password = bcrypt('$SEED_ADMIN_PASSWORD');
      \$u->permissions = 'superuser';
      \$u->activated = 1;
      \$u->save();
    " 2>&1 | tail -3 || true
  fi
fi

# we do this after the artisan commands to ensure that if the laravel
# log got created by root, we set the permissions back
touch /var/www/html/storage/logs/laravel.log
chown -R docker:root /var/www/html/storage/logs/laravel.log

exec supervisord -c /supervisord.conf
