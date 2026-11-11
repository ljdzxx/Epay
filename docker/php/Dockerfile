FROM php:8.3.36-fpm-bookworm

RUN set -eux; \
    for source in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources; do \
        [ -f "$source" ] || continue; \
        sed -i \
        -e 's#http://deb.debian.org/debian#http://mirrors.cloud.tencent.com/debian#g' \
        -e 's#http://security.debian.org/debian-security#http://mirrors.cloud.tencent.com/debian-security#g' \
        -e 's#http://deb.debian.org/debian-security#http://mirrors.cloud.tencent.com/debian-security#g' \
        "$source"; \
    done; \
    apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=30 update; \
    apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=30 install -y --no-install-recommends \
    libfreetype6-dev \
    libgmp-dev \
    libjpeg62-turbo-dev \
    libpng-dev \
    libzip-dev \
    zip \
    unzip \
    curl \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install pdo_mysql gd zip gmp bcmath \
    && rm -rf /var/lib/apt/lists/*

COPY docker/php/conf.d/zz-security.ini /usr/local/etc/php/conf.d/zz-security.ini

WORKDIR /opt/epay
