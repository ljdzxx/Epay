# PHP Docker 部署与升级说明

核对日期：2026-11-11。本次目标镜像为官方 `php:8.3.36-fpm-bookworm`。

PHP 官方在 2026-10-21 发布了 CVE-2026-109618、CVE-2026-109619 的修复，修复版本包括 8.3.36；2026-10-23 又建议禁用 session upload progress。Dockerfile 已升级基础镜像，镜像内配置 `session.upload_progress.enabled=0`。

同时兼容 Debian 的 `.sources` 软件源格式，保留原有扩展并补充依赖要求的 GMP、BCMath 扩展。Compose 的服务名仍是 `php`，容器名仍是 `epay-php`。

本文提供两条独立流程：没有旧容器时执行下方「全新部署」；已有运行中容器时执行后面的「从旧容器升级」。全新部署直接构建当前仓库锁定的 PHP 8.3.36，不需要先安装 PHP 8.0，也不需要读取旧容器信息。

## 全新部署

### 1. 准备服务器和完整代码

本方案沿用 `docker-compose.php-only.yml`：**Docker 只运行 PHP-FPM；Nginx 运行在同一台宿主机，MySQL/CynosDB 使用单独准备的实例。** 不是包含 Nginx、数据库的一体化 Compose。

准备 64 位 Linux 服务器、Docker Engine、Docker Compose 插件和宿主机 Nginx。把当前完整代码放到 `/opt/epay`，必须包含 `docker/`、`includes/vendor/`、`includes/composer.lock` 和 Compose 文件；不要只上传 Dockerfile。以下命令在服务器执行：

```bash
cd /opt/epay
EPAY_COMPOSE_PROJECT=epay
docker version
docker compose version
nginx -v
```

`EPAY_COMPOSE_PROJECT` 是本次部署的固定项目名，后续管理命令保持一致。当前 Compose 固定使用容器名 `epay-php` 和宿主机 `127.0.0.1:9000`，部署前需确保它们没有被其他实例占用。

### 2. 准备数据库与 config.php

先决定使用哪种数据库：

| 场景 | 操作 |
| --- | --- |
| 新建站点、空数据库 | 先创建空库和专用账号，随后运行网页安装程序初始化表。安装阶段需要建表等 DDL 权限。 |
| 新服务器接入已有易支付数据库 | 保留原库、原表前缀、配置和支付证书，恢复原 `install/install.lock`；不要执行全新安装或导入 `install.sql`。 |

运行账号需要本库的正常读写权限，不能使用仅有 `SELECT` 权限的临时排查账号。数据库地址必须能从 PHP 容器访问：云数据库填写其可达的连接地址及实际端口，并在数据库侧放行部署服务器的来源；`localhost`、`127.0.0.1` 在 PHP 容器里指容器自身，不能用来指代宿主机数据库。

配置文件固定为**项目根目录的 `/opt/epay/config.php`**。只有新目录尚无配置文件时才复制模板，然后手动填写真实配置：

```bash
test -f config.php || cp docker/php/config.php.example config.php
vi config.php
```

模板中的参数含义：

| 参数 | 填写内容 |
| --- | --- |
| `host` | 数据库连接地址，不带协议和端口 |
| `port` | 数据库实际端口，按实例配置填写 |
| `user` / `pwd` | 本次部署的数据库账号、密码 |
| `dbname` | 已经创建的数据库名 |
| `dbqz` | 表前缀，不带末尾下划线；`pay` 对应 `pay_config` 等表 |

当前程序不会自动读取 Compose 的 `MYSQL_*` 环境变量来替代这份配置。密码填写在 PHP 字符串中时须正确处理引号和反斜杠。接入已有库时保持原 `dbqz`，不要把数据库名误填成表前缀。

### 3. 构建镜像并检查依赖

```bash
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml config --quiet
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml build --pull --no-cache php
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml run --rm --no-deps php php -v
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml run --rm --no-deps php php-fpm -t
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml run --rm --no-deps php php -l config.php
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml run --rm --no-deps php php docker/php/check-dependencies.php
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml run --rm --no-deps php php -r 'foreach (["pdo_mysql", "gd", "zip", "gmp", "bcmath", "curl", "openssl", "mbstring", "libxml", "SimpleXML"] as $ext) { if (!extension_loaded($ext)) { fwrite(STDERR, "Missing extension: " . $ext . PHP_EOL); exit(1); } } if (filter_var(ini_get("session.upload_progress.enabled"), FILTER_VALIDATE_BOOLEAN)) { fwrite(STDERR, "Session upload progress is still enabled" . PHP_EOL); exit(1); } echo "Runtime configuration OK", PHP_EOL;'
```

应看到 PHP 8.3.36、FPM 和配置文件语法检查通过，以及 `Dependency compatibility checks OK`、`Runtime configuration OK`。任一步失败先处理错误，再继续。上述检查不会运行安装程序或连接数据库。

### 4. 设置写入权限并启动 PHP

以下命令使用镜像内的 `www-data` 用户设置必要权限，不依赖宿主机用户名与容器 UID 一致。源码保持正常可读，数据库配置只供属主和 PHP 所在组读取；安装锁、后台登录锁及上传目录需要可写。

镜像新增了启动入口：每次启动 PHP-FPM 服务前，会自动修正挂载目录中**所有插件、所有商户**的读取权限。权限处理使用容器内 `www-data` 的组 ID；FPM 工作进程仍使用 `www-data`，启动入口需以默认 root 用户运行。不要给 Compose 的 PHP 服务添加 `user: www-data`。

```bash
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml run --rm --no-deps --user root php sh -eu -c '
    mkdir -p assets/uploads
    chgrp www-data config.php
    chmod 640 config.php
    chown www-data:www-data install admin assets/uploads
    chmod 755 install admin assets/uploads
'
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml up -d --no-build php
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml ps
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml logs --tail=100 php
```

项目目录绑定到容器 `/opt/epay`，其中包含 `plugins/`，不需要再单独挂载插件目录。配置、上传文件、支付证书和安装锁保存在宿主机，不会随容器重建丢失。迁移时仍须从旧服务器同步真实证书；仓库代码和数据库不能替代这些文件。

启动入口的具体处理范围：

- 给插件目录补充 PHP 所在组的读取、进入权限，给插件普通文件补充组读取权限；不额外授予插件源码写权限。
- 递归处理所有名为 `cert` 的插件证书目录，包括商户子目录及 `inc/cert`。证书目录设为 `2770`，普通证书和私钥文件设为 `640`；SDK 会自动更新的 `cert.pem` 设为 `660`。因此迁移过来的 `root:root 600` 私钥也可被 PHP 读取。
- 使用 setgid 让新建证书子目录继承组。不跟随插件树中的符号链接；证书应作为真实文件放在挂载的项目内。
- 不加载应用配置、不连接数据库、不触发安装、升级或支付请求。运行 `php ...`、`php-fpm -t` 等诊断命令时跳过自动修正。正式启动时如权限处理失败，容器会报告错误并停止启动。

**运行中新增或替换任意商户证书后**，执行统一命令即可生效，无需填写商户号，也无需重启：

```bash
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml exec -T --user root php epay-fix-plugin-permissions
```

自动上传或同步证书时，将这条命令放在同步成功后的步骤中。启动入口不是文件监听服务：复制工具保留的 `600` 权限或移动进来的文件不会因父目录 setgid 自动变为可读；新文件在上传后执行该命令，或在下次容器启动时统一修正。其他插件自定义日志目录按其实际需要另行设置写权限。

镜像构建后可运行权限回归检查。该检查仅在容器 `/tmp` 创建模拟文件，验证多插件、多商户、后续新增商户、平台证书写权限、重复执行以及启动命令分流，不读取真实证书、不连接数据库：

```bash
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml run --rm --no-deps --user root php sh docker/php/tests/test-permissions.sh
```

### 5. 配置宿主机 Nginx

提供了可复制的配置模板：`docker/nginx/epay.conf.example`。它包含本项目的伪静态规则和 FastCGI 配置，初始只监听 `127.0.0.1:8080`，用于通过 SSH 隧道完成初始化。按宿主机 Nginx 的实际 include 目录安装；下面以 `/etc/nginx/conf.d/` 为例，已有同名配置时先核对内容：

```bash
sudo cp -i docker/nginx/epay.conf.example /etc/nginx/conf.d/epay.conf
sudo nginx -t && sudo nginx -s reload
```

如果 Nginx 服务尚未启动，检查配置通过后启动服务（例如 `sudo systemctl start nginx`），不执行 reload。

在**你自己的电脑**建立隧道，替换 SSH 用户与服务器地址，并保持终端开启：

```bash
ssh -N -L 18080:127.0.0.1:8080 deploy@your-server
```

浏览器使用 `http://127.0.0.1:18080/` 访问。不要通过浏览器访问 `9000`，它是 FastCGI 端口。

如果宿主机代码不在 `/opt/epay`，修改模板的 `root` 为真实宿主机路径；`fastcgi_param SCRIPT_FILENAME /opt/epay$fastcgi_script_name;` 仍然使用**容器内路径**。如果 Nginx 也在容器里，不能照抄这个宿主机模板的 `127.0.0.1:9000`，需要另行配置共享网络和代码挂载。

### 6. 初始化空数据库，或接入已有库

**空数据库：** 通过 SSH 隧道打开 `http://127.0.0.1:18080/install/`，到数据库配置页后选择页面中的“已事先填写好 config.php，跳过这一步”链接，使用第 2 步保存的配置；确认是新建空库后安装数据表。安装成功后必须存在 `install/install.lock`。按安装页面提示进入 `/admin/`，立即修改默认管理员密码和支付操作密码，再设置站点参数。

**已有数据库：** 使用原配置和原 `install/install.lock`，直接访问后台。若只缺安装锁，确认数据库已完成安装后可执行 `touch install/install.lock`。不要对已有库点击“强制全新安装”，也不要导入 `install/install.sql`：该脚本包含删表语句。若应用提示数据库结构版本落后，应先备份，再按应用数据库升级流程处理；新建 PHP 容器本身不需要重新建表。

初始化完成后，在 Nginx 的 `server` 块中增加下行并重新检查、加载配置，关闭安装入口：

```nginx
location ^~ /install/ { deny all; }
```

### 7. 配置正式 HTTPS 域名并验收

将域名解析到服务器并准备对应证书。把模板中初始的 `listen 127.0.0.1:8080;`、`server_name _;` 替换为下面内容，其余 `root`、伪静态和 PHP 处理规则保留；域名和证书路径按实际填写：

```nginx
listen 443 ssl;
server_name pay.example.com;
ssl_certificate /etc/nginx/ssl/pay.example.com/fullchain.pem;
ssl_certificate_key /etc/nginx/ssl/pay.example.com/privkey.pem;
```

按需要另加 HTTP 跳转的 `server` 块：

```nginx
server {
    listen 80;
    server_name pay.example.com;
    return 301 https://pay.example.com$request_uri;
}
```

执行 `sudo nginx -t && sudo nginx -s reload`，放行对外的 443 端口（使用 HTTP 跳转时还需 80）。后台站点地址、支付平台回调地址和授权域名使用正式 HTTPS 域名，不能沿用隧道的 `127.0.0.1:18080`。

```bash
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml exec -T php php -v
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml exec -T php php docker/php/check-dependencies.php
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml exec -T php php-fpm -i | grep -F 'session.upload_progress.enabled'
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml logs --tail=100 php
```

确认后台登录、静态资源、域名及业务配置正常，再在测试环境核验支付回调和金额计算。定时结算任务是宿主机的独立配置，本 Compose 不会自动创建；接入已有库时不要重复创建已有任务，也不要把手动触发生产结算当作部署检查。

以上完成后无需继续执行下方的旧容器升级步骤。当前编写环境没有 Docker 和 Nginx，本文的 Linux 构建、Nginx 配置检查和首次安装仍需在部署服务器实际执行。

## 两项发现的处理结果

1. **Composer 自动加载文件中的非标准代码已清理，并整体重建依赖。** 原代码涉及把应用敏感配置写入响应 Cookie。现在的 `includes/vendor/` 来自可信 Composer 和上游发行包，自动加载文件重新生成，不保留原目录中的额外文件。新增 `includes/composer.lock` 固定本次核验的版本。
2. **当前仓库未发现 Swoole Loader 的实际依赖。** `admin/loader_helper.php` 是旧版安装帮助页，没有调用方；仓库不存在 `assets/loader/` 或 Loader 二进制，也未找到其他 Swoole Loader、ionCube、SourceGuardian 引用。该帮助页保持原样，本次镜像不安装 Loader。服务器额外安装但未纳入仓库的插件仍需通过实际扩展清单和测试环境核对。

原 SDK 的 Composer 元数据版本与实际源码不一致，本次按实际功能核对上游版本，没有按旧元数据回退 SDK。锁定的直接依赖为：

| 依赖 | 版本 |
| --- | --- |
| `cccyun/alipay-sdk` | 1.10 |
| `cccyun/wechatpay-sdk` | 1.11 |
| `cccyun/qqpay-sdk` | 1.3 |
| `lpilp/guomi` | 2.0.0 |

重建时 Composer 拦截了旧 `mdanter/ecc` 1.0.0 的安全公告。采用上游 `lpilp/guomi` 2.0.0 后，依赖切换为 `paragonie/ecc` 2.6.0、`genkgo/php-asn1` 2.9.0 和 `paragonie/sodium_compat` 2.5.2，未忽略安全公告或关闭检查。2026-11-11 的 `composer audit --locked` 结果为无已知安全公告、无废弃依赖；这不代表对应用做过完整安全审计。

历史上是否发生敏感配置泄露无法仅凭代码判断。上线清理后，应安排应用系统密钥轮换，并按实际使用情况处理关联会话或接口凭据。本次未修改生产密钥。

## 从旧容器升级

### 部署前

在服务器的**独立发布目录**准备完整项目，并同步本次的 `docker/php/`、`includes/composer.json`、`includes/composer.lock` 和完整 `includes/vendor/`。不能只部署 Dockerfile，也不能把新依赖逐文件覆盖到仍在提供服务的旧目录；旧 `fgrosse/`、`mdanter/` 目录不应出现在新版本中。

**新版锁定依赖最低要求 PHP 8.1 和 64 位环境。** 如果线上仍是 PHP 8.0，先覆盖 `vendor` 会立即导致自动加载失败。因此须先在新目录构建和检查 PHP 8.3 镜像，再一起切换运行时与代码。配置、支付证书及需持久化的数据应沿用现有部署的持久化方案，切换前完成必要的最终同步。

以下命令在 Linux 部署服务器的新发布目录执行。先读取当前容器的 Compose 项目名，确保新目录继续操作同一项目：

```bash
EPAY_COMPOSE_PROJECT="$(docker inspect epay-php --format '{{ index .Config.Labels "com.docker.compose.project" }}')"
if [ -z "$EPAY_COMPOSE_PROJECT" ] || [ "$EPAY_COMPOSE_PROJECT" = '<no value>' ]; then
    echo '无法确定原 Compose 项目名，请先核对原部署配置' >&2
    exit 1
fi
```

先确认旧版本，记录容器内曾手动添加的扩展、配置、证书或其他文件。镜像重建不会保留未挂载的容器内部修改。

```bash
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml exec -T php php -v
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml exec -T php php --ini
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml exec -T php php -m
```

如果选择在可信构建环境重新安装依赖，使用锁文件执行 `composer --working-dir=includes install --no-dev --no-plugins --no-scripts --prefer-dist --no-interaction`，不要在部署时执行 `composer update`。该操作应在新目录使用 PHP 8.3 和所需扩展完成，不能沿用未经清理的旧 `vendor`。

### 构建及运行时检查

以下步骤不会替换正在运行的 PHP 容器，也不会加载应用入口或执行数据库操作。

```bash
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml config --quiet
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml build --pull --no-cache php
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml run --rm --no-deps php php -v
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml run --rm --no-deps php php-fpm -t
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml run --rm --no-deps php php -r 'foreach (["pdo_mysql", "gd", "zip", "gmp", "bcmath", "curl", "openssl", "mbstring", "libxml", "SimpleXML"] as $ext) { if (!extension_loaded($ext)) { fwrite(STDERR, "Missing extension: " . $ext . PHP_EOL); exit(1); } } if (filter_var(ini_get("session.upload_progress.enabled"), FILTER_VALIDATE_BOOLEAN)) { fwrite(STDERR, "Session upload progress is still enabled" . PHP_EOL); exit(1); } echo "Runtime configuration OK", PHP_EOL;'
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml run --rm --no-deps php php docker/php/check-dependencies.php
```

版本应为 8.3.36，FPM 配置检查通过，最后两项分别输出 `Runtime configuration OK` 和 `Dependency compatibility checks OK`。依赖检查只加载 Composer，使用临时生成的密钥和本地测试文本，不加载应用配置，不连接数据库或支付平台。

本地已用 PHP 8.3.36 检查 460 个项目 PHP 文件和 305 个依赖 PHP 文件，语法检查全部通过；依赖平台检查、支付 SDK 类加载、SM2 签名验签与加解密、SM3 标准向量、SM4 与 OpenSSL 互操作检查通过。本地环境没有 Docker，尚未执行 Linux 镜像构建和 FPM 检查。这些离线检查不等于业务兼容性验证。上线前应在独立测试环境使用测试数据库验证登录、普通订单处理、通知验签和结算金额计算，不执行生产转账或重新触发生产结算任务。

### 切换运行容器

完成兼容性验证后，在低流量时段执行。重建会造成短暂中断，容器内未持久化的会话可能丢失。

```bash
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml up -d --no-deps --no-build --force-recreate php
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml exec -T php php -v
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml exec -T php php -r 'echo "upload_progress=", ini_get("session.upload_progress.enabled"), PHP_EOL;'
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml exec -T php php-fpm -i | grep -F 'session.upload_progress.enabled'
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml exec -T php php docker/php/check-dependencies.php
docker compose -p "$EPAY_COMPOSE_PROJECT" -f docker-compose.php-only.yml logs --tail=100 php
```

应看到 PHP 8.3.36、CLI 的 `upload_progress=0`，以及 FPM 对应设置为 `Off`。若服务器额外挂载了 INI 或配置了 FPM pool 覆盖项，需要一并核对最终设置。

本次同时新增镜像内的 `epay-entrypoint` 和 `epay-fix-plugin-permissions`。需同步整个 `docker/php/` 后重建镜像、重建容器；只更新宿主机脚本或重启旧镜像不会获得新的启动入口。新容器启动日志应包含 `Plugin and merchant certificate permissions prepared`，表示已处理当前挂载目录中的插件和商户证书权限。

本项目通过 `build:` 创建应用镜像，因此只运行 `docker compose pull` 或 `docker compose restart` 不会完成此次升级。宿主机升级 PHP 也不会替换容器内的 PHP。

保留 `127.0.0.1:9000:9000` 的端口绑定，沿用现有 Nginx 转发配置；若 Nginx 的静态文件根目录使用旧发布目录，需同步切换到新代码。数据库不属于这份 Compose 的服务，升级命令不包含数据库迁移。回滚时应使用已清理的可信代码和兼容运行时，不应重新启用包含可疑自动加载代码的旧 `vendor`。

## 官方依据

- PHP 官方 2026 年公告：<https://www.php.net/archive/2026.php>
- PHP 支持周期：<https://www.php.net/supported-versions.php>
- 官方 PHP 镜像标签：<https://github.com/docker-library/official-images/blob/master/library/php>
- Compose build：<https://docs.docker.com/reference/cli/docker/compose/build/>
- Compose up：<https://docs.docker.com/reference/cli/docker/compose/up/>
