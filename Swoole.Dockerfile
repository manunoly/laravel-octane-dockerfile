# Accepted values: 8.3 - 8.2 - 8.1
ARG PHP_VERSION=8.3

ARG COMPOSER_VERSION=latest

###########################################
# Build frontend assets with NPM
###########################################

ARG NODE_VERSION=20-alpine

FROM node:${NODE_VERSION} as build

ENV ROOT=/var/www/html

WORKDIR ${ROOT}

RUN npm config set update-notifier false && npm set progress=false

COPY package*.json ./

RUN if [ -f $ROOT/package-lock.json ]; \
  then \
    npm ci --no-optional --loglevel=error --no-audit; \
  else \
    npm install --no-optional --loglevel=error --no-audit; \
  fi

COPY . .

RUN npm run build

###########################################

FROM composer:${COMPOSER_VERSION} AS vendor

FROM php:${PHP_VERSION}-cli-bookworm

LABEL maintainer="SMortexa <seyed.me720@gmail.com>"

ARG WWWUSER=1000
ARG WWWGROUP=1000
ARG TZ=UTC

ENV DEBIAN_FRONTEND=noninteractive \
  TERM=xterm-color \
  WITH_HORIZON=false \
  WITH_SCHEDULER=false \
  OCTANE_SERVER=swoole \
  NON_ROOT_USER=octane \
  ROOT=/var/www/html

ENV USE_MSSQL=true
ENV USE_POSTGRES=

WORKDIR ${ROOT}

SHELL ["/bin/bash", "-eou", "pipefail", "-c"]

RUN ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime \
  && echo ${TZ} > /etc/timezone

RUN apt-get update; \
  apt-get upgrade -yqq; \
  pecl -q channel-update pecl.php.net; \
  apt-get install -yqq --no-install-recommends --show-progress \
  apt-utils \
  gnupg \
  git \
  curl \
  wget \
  nano \
  rsync \
  ncdu \
  sqlite3 \
  libcurl4-openssl-dev \
  ca-certificates \
  supervisor \
  libmemcached-dev \
  libz-dev \
  libbrotli-dev \
  libpq-dev \
  libjpeg-dev \
  libpng-dev \
  librsvg2-bin \
  libfreetype6-dev \
  libssl-dev \
  libwebp-dev \
  libmcrypt-dev \
  libldap2-dev \
  libonig-dev \
  libreadline-dev \
  libsodium-dev \
  libsqlite3-dev \
  libmagickwand-dev \
  libzip-dev zip unzip \
  libargon2-1 \
  libidn2-0 \
  libpcre2-8-0 \
  librdkafka-dev \
  libpcre3 \
  libxml2 \
  libxslt-dev \
  libzstd1 \
  libc-ares-dev \
  procps \
  default-mysql-client \
  libbz2-dev \
  zlib1g-dev \
  libicu-dev \
  g++ \
  # Install PHP extensions
  && docker-php-ext-install \
  bz2 \
  pcntl \
  mbstring \
  bcmath \
  sockets \
  opcache \
  exif \
  && docker-php-ext-configure pdo_mysql && docker-php-ext-install pdo_mysql \
  && docker-php-ext-configure zip && docker-php-ext-install zip \
  && docker-php-ext-configure intl && docker-php-ext-install intl \
  && docker-php-ext-configure gd \
  --prefix=/usr \
  --with-jpeg \
  --with-webp \
  --with-freetype && docker-php-ext-install gd \
  && pecl -q install -o -f redis && docker-php-ext-enable redis \
  && pecl -q install -o -f rdkafka && docker-php-ext-enable rdkafka \
  && pecl -q install -o -f memcached && docker-php-ext-enable memcached \
  && pecl -q install -o -f igbinary && docker-php-ext-enable igbinary \
  && pecl -q install -o -f swoole && docker-php-ext-enable swoole \
  && docker-php-ext-configure ldap --with-libdir=lib/$(gcc -dumpmachine) && docker-php-ext-install ldap

RUN if [ "$USE_POSTGRES" == "true" ]; then \
  apt-get install -yqq --no-install-recommends --show-progress \
  postgresql-client \
  postgis \
  && docker-php-ext-install pdo_pgsql pgsql; \
  fi

RUN if [ "${USE_MSSQL}" = "true" ]; then \
  echo "Installing Microsoft Drivers for PHP for SQL Server" \
  && curl -sSL https://packages.microsoft.com/keys/microsoft.asc | apt-key add - \
  && curl -sL https://packages.microsoft.com/config/ubuntu/22.04/prod.list > /etc/apt/sources.list.d/mssql-release.list \
  && apt-get update \
  && ACCEPT_EULA=Y apt-get install -y msodbcsql17 mssql-tools \
  && apt-get install -y unixodbc-dev \
  && pecl install sqlsrv pdo_sqlsrv swoole \
  && echo "extension=sqlsrv.so" >> /usr/local/etc/php/conf.d/sqlsrv.ini \
  && echo "extension=pdo_sqlsrv.so" >> /usr/local/etc/php/conf.d/pdo_sqlsrv.ini; \
  fi

RUN apt-get -y autoremove \
  && apt-get clean \
  && docker-php-source delete \
  && pecl clear-cache \
  && rm -R /tmp/pear \
  && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
  && rm /var/log/lastlog /var/log/faillog

RUN wget -q "https://github.com/aptible/supercronic/releases/download/v0.2.29/supercronic-linux-amd64" \
  -O /usr/bin/supercronic \
  && chmod +x /usr/bin/supercronic \
  && mkdir -p /etc/supercronic \
  && echo "*/1 * * * * php ${ROOT}/artisan schedule:run --verbose --no-interaction" > /etc/supercronic/laravel

RUN userdel --remove --force www-data \
  && groupadd --force -g ${WWWGROUP} ${NON_ROOT_USER} \
  && useradd -ms /bin/bash --no-log-init --no-user-group -g ${WWWGROUP} -u ${WWWUSER} ${NON_ROOT_USER}

RUN chown -R ${NON_ROOT_USER}:${NON_ROOT_USER} ${ROOT} /var/{log,run}

RUN chmod -R a+rw /var/{log,run}

USER ${NON_ROOT_USER}

COPY --chown=${NON_ROOT_USER}:${NON_ROOT_USER} --from=vendor /usr/bin/composer /usr/bin/composer
COPY --chown=${NON_ROOT_USER}:${NON_ROOT_USER} composer* ./

RUN composer install \
  --no-dev \
  --no-interaction \
  --no-autoloader \
  --no-ansi \
  --no-scripts \
  --audit

COPY --chown=${NON_ROOT_USER}:${NON_ROOT_USER} . .
COPY --chown=${NON_ROOT_USER}:${NON_ROOT_USER} --from=build ${ROOT}/public public

RUN mkdir -p \
  storage/framework/{sessions,views,cache,testing} \
  storage/logs \
  bootstrap/cache

COPY --chown=${NON_ROOT_USER}:${NON_ROOT_USER} deployment/octane/Swoole/supervisord.swoole.conf /etc/supervisor/conf.d/
COPY --chown=${NON_ROOT_USER}:${NON_ROOT_USER} deployment/supervisord.*.conf /etc/supervisor/conf.d/
COPY --chown=${NON_ROOT_USER}:${NON_ROOT_USER} deployment/php.ini /usr/local/etc/php/conf.d/99-octane.ini
COPY --chown=${NON_ROOT_USER}:${NON_ROOT_USER} deployment/start-container /usr/local/bin/start-container

RUN composer install \
  --classmap-authoritative \
  --no-interaction \
  --no-ansi \
  --no-dev \
  && composer clear-cache \
  && php artisan storage:link

RUN chmod +x /usr/local/bin/start-container

RUN cat deployment/utilities.sh >> ~/.bashrc

EXPOSE 80

ENTRYPOINT ["start-container"]

HEALTHCHECK --start-period=5s --interval=2s --timeout=5s --retries=8 CMD php artisan octane:status || exit 1
