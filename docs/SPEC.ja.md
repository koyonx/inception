# Inception 詳細仕様書（日本語）— 必須部分のみ

> 本書はこのリポジトリの**実装仕様**を日本語で記述したものです。
> 背景知識・設計理由・評価対策は [`KNOWLEDGE.ja.md`](KNOWLEDGE.ja.md) を参照してください。
> このブランチは課題の**必須部分（mandatory part）のみ**を実装しています。ボーナスサービスは含みません。

- 対象課題: 42 Cursus **Inception** (Version 5.3)
- ログイン: `kkuramot` / ドメイン: `kkuramot.42.fr` / データパス: `/home/kkuramot/data`
- ベースイメージ: `debian:bookworm`（安定版のひとつ前 = Debian 12）
- Docker Compose: v2（`docker compose` サブコマンド）

---

## 目次

1. [システム全体像](#1-システム全体像)
2. [ディレクトリ構成](#2-ディレクトリ構成)
3. [設定値の管理（.env とシークレット）](#3-設定値の管理env-とシークレット)
4. [docker-compose.yml 仕様](#4-docker-composeyml-仕様)
5. [サービス仕様](#5-サービス仕様)
6. [Makefile 仕様](#6-makefile-仕様)
7. [起動シーケンス](#7-起動シーケンス)
8. [通信経路とポート一覧](#8-通信経路とポート一覧)
9. [データ永続化仕様](#9-データ永続化仕様)
10. [セキュリティ仕様](#10-セキュリティ仕様)
11. [課題要件との対応表](#11-課題要件との対応表)
12. [動作検証手順と実測結果](#12-動作検証手順と実測結果)

---

## 1. システム全体像

### 1.1 構成図

```
                       外部（ブラウザ）
                             │
                       :443  │  HTTPS (TLSv1.2 / TLSv1.3)
        ┌────────────────────┼──────────────────────────────────┐
        │  ホスト（VM）       │                                  │
        │                    ▼                                  │
        │   ┌── docker network "inception" (bridge) ─────────┐  │
        │   │                                                │  │
        │   │  ┌───────┐  fastcgi  ┌───────────┐  mysql  ┌──────┐ │
        │   │  │ nginx │──:9000──► │ wordpress │──:3306─►│maria │ │
        │   │  │ :443  │           │ (php-fpm) │         │ db   │ │
        │   │  └───┬───┘           └─────┬─────┘         └───┬──┘ │
        │   │      │                     │                   │    │
        │   └──────┼─────────────────────┼───────────────────┼────┘
        │          │  (:ro)              │                   │     │
        │          ▼                     ▼                   ▼     │
        │    named volume "wordpress"        named volume "mariadb" │
        │    /home/kkuramot/data/wordpress   /home/kkuramot/data/mariadb
        └───────────────────────────────────────────────────────────┘
```

### 1.2 コンテナ一覧

| # | サービス名 | イメージタグ | 役割 | 公開ポート |
|---|---|---|---|---|
| 1 | `nginx` | `nginx:inception` | 唯一の入口・TLS 終端・FastCGI 中継 | `443` |
| 2 | `wordpress` | `wordpress:inception` | WordPress + php-fpm | なし（`expose 9000`） |
| 3 | `mariadb` | `mariadb:inception` | データベース | なし（`expose 3306`） |

> **イメージ名 = サービス名**（課題要件）。タグは `latest` 禁止のため `:inception` を付与。

### 1.3 設計原則

| 原則 | 実装 |
|---|---|
| 1コンテナ1サービス | nginx に PHP は入れず、WordPress に nginx は入れない |
| プロセスは PID 1 | 全 entrypoint が末尾で `exec` |
| 無限ループ禁止 | `tail -f` / `sleep infinity` / `while true` を一切使わない。DB 待機のみ**回数上限付き**リトライ（30回×2秒） |
| 冪等な初期化 | 2回目以降の起動は初期化をスキップし、データを壊さない |
| 秘密情報の分離 | パスワードは Docker secrets（ファイル）、それ以外は `.env` |
| 自前ビルド | Alpine/Debian 以外の既製イメージを使わない |
| 必須範囲に限定 | サービス3・ボリューム2・ネットワーク1・公開ポート1。すべてが subject の記述に対応する |

---

## 2. ディレクトリ構成

```
.
├── Makefile                          唯一の操作入口（docker compose を駆動）
├── .gitignore                        secrets/*.txt, srcs/.env, subject PDF を除外
├── README.md                         課題必須（英語）
├── USER_DOC.md                       課題必須（英語）・利用者向け
├── DEV_DOC.md                        課題必須（英語）・開発者向け
├── docs/
│   ├── SPEC.ja.md                    本書
│   └── KNOWLEDGE.ja.md               背景知識・評価対策
├── secrets/                          git 管理外（.gitkeep のみ追跡）
│   ├── .gitkeep                      生成されるファイルの説明
│   ├── credentials.txt               WP_ADMIN_PASSWORD= / WP_USER_PASSWORD=
│   ├── db_password.txt               MariaDB の WordPress 用ユーザーパスワード
│   └── db_root_password.txt          MariaDB の root パスワード
└── srcs/
    ├── .env                          git 管理外（make setup が生成）
    ├── .env.example                  追跡されるテンプレート（機密なし）
    ├── docker-compose.yml
    └── requirements/
        ├── mariadb/
        │   ├── Dockerfile
        │   ├── .dockerignore
        │   ├── conf/50-server.cnf
        │   └── tools/docker-entrypoint.sh
        ├── nginx/
        │   ├── Dockerfile
        │   ├── .dockerignore
        │   ├── conf/default.conf     vhost テンプレート
        │   └── tools/docker-entrypoint.sh
        └── wordpress/
            ├── Dockerfile
            ├── .dockerignore
            ├── conf/www.conf         php-fpm プール定義
            └── tools/docker-entrypoint.sh
```

各サービスは **`Dockerfile` + `conf/`（イメージへ COPY する設定）+ `tools/`（entrypoint）** という同じ形をとります。

`.dockerignore` は各ビルドコンテキストで「全部拒否してから必要なものだけ許可」する安全側の記述です。

```
*
!Dockerfile
!conf
!conf/**
!tools
!tools/**
```

---

## 3. 設定値の管理（.env とシークレット）

### 3.1 分離ルール

| 種別 | 置き場所 | 渡し方 | git |
|---|---|---|---|
| 非機密の設定 | `srcs/.env` | `env_file:` → 環境変数 | 除外（テンプレートのみ追跡） |
| パスワード類 | `secrets/*.txt` | `secrets:` → `/run/secrets/<name>` | 除外 |

判断基準は「`git log` に残って困る値かどうか」。困るなら `secrets/`。

### 3.2 `srcs/.env.example` の全変数

`make setup` がこのファイルをコピーし、`__LOGIN__` を `LOGIN`（既定 `kkuramot`）に置換して `srcs/.env` を生成します。

| 変数 | 既定値 | 用途 | 使用サービス |
|---|---|---|---|
| `LOGIN` | `kkuramot` | 参照用 | — |
| `DOMAIN_NAME` | `kkuramot.42.fr` | 証明書 CN / vhost / WP の URL | nginx, wordpress |
| `DATA_PATH` | `/home/kkuramot/data` | 名前付きボリュームの実体 | compose |
| `MYSQL_HOST` | `mariadb` | DB 接続先ホスト名 | wordpress |
| `MYSQL_PORT` | `3306` | DB 接続先ポート | wordpress |
| `MYSQL_DATABASE` | `wordpress` | データベース名 | mariadb, wordpress |
| `MYSQL_USER` | `wp_user` | DB ユーザー名 | mariadb, wordpress |
| `WP_VERSION` | `6.7.1` | 取得する WordPress のバージョン | wordpress |
| `WP_TITLE` | `Inception` | サイトタイトル | wordpress |
| `WP_URL` | `https://kkuramot.42.fr` | 参照用 | wordpress |
| `WP_ADMIN_USER` | `chief_dreamer` | 管理者名（**admin を含まないこと**） | wordpress |
| `WP_ADMIN_EMAIL` | `chief_dreamer@kkuramot.42.fr` | 管理者メール | wordpress |
| `WP_USER` | `cobb` | 2人目のユーザー名 | wordpress |
| `WP_USER_EMAIL` | `cobb@kkuramot.42.fr` | 2人目のメール | wordpress |
| `WP_USER_ROLE` | `author` | 2人目の権限 | wordpress |

### 3.3 シークレット定義

```yaml
secrets:
  db_password:      { file: ../secrets/db_password.txt }
  db_root_password: { file: ../secrets/db_root_password.txt }
  credentials:      { file: ../secrets/credentials.txt }
```

| ファイル | 中身 | マウント先 | 参照するサービス |
|---|---|---|---|
| `db_root_password.txt` | 平文パスワード1行 | `/run/secrets/db_root_password` | mariadb |
| `db_password.txt` | 平文パスワード1行 | `/run/secrets/db_password` | mariadb, wordpress |
| `credentials.txt` | `WP_ADMIN_PASSWORD=…` / `WP_USER_PASSWORD=…` の2行 | `/run/secrets/credentials` | wordpress |

生成は `make secrets` が担当し、`openssl rand -base64 24`（DB）/ `18`（WP）で作成、`chmod 600`。**既存ファイルは上書きしません**。

entrypoint 側の読み取りは末尾改行を除去する共通関数で行います。

```sh
read_secret() {
	[ -r "$1" ] || { echo "FATAL: missing secret $1" >&2; exit 1; }
	tr -d '\r\n' < "$1"
}
```

---

## 4. docker-compose.yml 仕様

### 4.1 ネットワーク

```yaml
networks:
  inception:
    name: inception
    driver: bridge
```

- `network_mode: host` / `links:` / `--link` は不使用（課題で禁止）。
- Docker 内蔵 DNS（`127.0.0.11`）により、サービス名がそのままホスト名になります。

### 4.2 ボリューム

2つとも `local` ドライバの**名前付きボリューム**で、`driver_opts` により実体をホストの `${DATA_PATH}` 配下に固定しています。

```yaml
volumes:
  wordpress:
    name: wordpress
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${DATA_PATH}/wordpress
```

| ボリューム名 | マウント先 | 保持内容 |
|---|---|---|
| `mariadb` | `mariadb:/var/lib/mysql` | データベース本体 |
| `wordpress` | `wordpress:/var/www/html`（`nginx` は `:ro`） | WordPress 本体・テーマ・プラグイン・アップロード |

> `name:` を明示しているため、Compose のプロジェクト名接頭辞が付かず `docker volume ls` に `wordpress` としてそのまま現れます。

### 4.3 サービス共通の設定

| キー | 値 | 意図 |
|---|---|---|
| `build.context` | `./requirements/<service>` | Dockerfile を Makefile 経由で呼ぶ |
| `image` | `<service>:inception` | イメージ名 = サービス名、`latest` 回避 |
| `container_name` | `<service>` | `docker logs nginx` などを簡潔に |
| `env_file` | `.env` | 非機密設定の注入 |
| `restart` | `always` | クラッシュ時の自動再起動（課題要件） |
| `networks` | `[inception]` | 単一のユーザー定義ブリッジ |

### 4.4 ヘルスチェックと依存関係

| サービス | ヘルスチェック | 間隔 / 猶予 |
|---|---|---|
| `mariadb` | `mariadb-admin ping --silent -h localhost -u root -p"$(cat /run/secrets/db_root_password)"` | 10s / start_period 30s / retries 10 |
| `wordpress` | `pgrep php-fpm > /dev/null && test -f /var/www/html/wp-config.php` | 10s / start_period 60s / retries 10 |
| `nginx` | `curl -kfsS https://localhost/ -o /dev/null` | 15s / start_period 30s / retries 5 |

依存関係:

```yaml
wordpress:
  depends_on:
    mariadb: { condition: service_healthy }
nginx:
  depends_on: [wordpress]
```

---

## 5. サービス仕様

### 5.1 mariadb

#### イメージ

| 項目 | 内容 |
|---|---|
| ベース | `debian:bookworm` |
| 導入パッケージ | `mariadb-server`, `mariadb-client`, `procps` |
| MariaDB バージョン | 10.11.x（bookworm 提供） |
| 設定ファイル | `/etc/mysql/mariadb.conf.d/50-server.cnf` |
| ENTRYPOINT | `/usr/local/bin/docker-entrypoint.sh` |
| CMD | `["mariadbd"]` |

**重要**: `apt-get install mariadb-server` はイメージ内 `/var/lib/mysql` にシステムテーブルを作ってしまいます。空のボリュームをマウントすると Docker がその中身をボリュームへコピーするため、entrypoint が「初期化済み」と誤判定します。したがって Dockerfile の最後で

```dockerfile
rm -rf /var/lib/mysql/* && \
chown -R mysql:mysql /var/run/mysqld /var/lib/mysql
```

として**空のデータディレクトリを出荷**します。

#### `conf/50-server.cnf` の要点

| 設定 | 値 | 理由 |
|---|---|---|
| `bind-address` | `0.0.0.0` | wordpress コンテナから接続させる（ホストには公開しない） |
| `port` | `3306` | — |
| `skip-name-resolve` | 有効 | 逆引き DNS を行わず接続を高速化 |
| `character-set-server` | `utf8mb4` | 絵文字を含む記事に対応 |
| `collation-server` | `utf8mb4_unicode_ci` | — |
| `max_connections` | `100` | — |
| `innodb_buffer_pool_size` | `128M` | VM 前提の控えめな設定 |
| `log_error` | **設定しない** | 未設定だと stderr に出力され、`docker logs` で読める |

#### entrypoint の処理フロー

```
1. /run/secrets/db_root_password, /run/secrets/db_password を読む（無ければ即異常終了）
2. MYSQL_DATABASE / MYSQL_USER の未設定チェック（:"${VAR:?}"）
3. mkdir -p /run/mysqld && chown -R mysql:mysql /run/mysqld /var/lib/mysql
4. if [ ! -d /var/lib/mysql/mysql ]:            ← 初回のみ
     4-1. mariadb-install-db --user=mysql --datadir=/var/lib/mysql
              --skip-test-db --auth-root-authentication-method=normal
     4-2. mariadbd --user=mysql --bootstrap <<SQL
              ALTER USER 'root'@'localhost' IDENTIFIED BY '<root pw>';
              DELETE FROM mysql.global_priv
                 WHERE User='root' AND Host<>'localhost';    -- パスワード無し root を削除
              DELETE FROM mysql.global_priv WHERE User='';   -- 匿名ユーザー削除
              DROP DATABASE IF EXISTS test;
              CREATE DATABASE IF NOT EXISTS `wordpress` CHARACTER SET utf8mb4 …;
              CREATE USER IF NOT EXISTS 'wp_user'@'%' IDENTIFIED BY '<db pw>';
              GRANT ALL PRIVILEGES ON `wordpress`.* TO 'wp_user'@'%';
              FLUSH PRIVILEGES;
          SQL
   else: 「既存データを検出、初期化をスキップ」とログ出力
5. exec mariadbd --user=mysql          ← PID 1
```

`--bootstrap` は **SQL を流し終えたら終了する単発モード**です。バックグラウンドでサーバを起こして後で殺す、といったハック（およびそのための sleep ループ）が不要になります。

権限設計:

- `root` は `localhost` のみ（UNIX ソケット経由）。ネットワーク越しの root ログインは不可。
- **`mariadb-install-db` は `root@127.0.0.1` / `root@::1` / `root@<hostname>` を
  パスワード無しで作ります**。そのままだとコンテナ内からパスワード無しで root に
  入れてしまうため、bootstrap で `localhost` 以外の root を削除しています。
- `wp_user@'%'` は `wordpress` データベースに対してのみ全権。他 DB には触れません。

### 5.2 wordpress（WordPress + php-fpm）

#### イメージ

| 項目 | 内容 |
|---|---|
| ベース | `debian:bookworm` |
| PHP | `php8.2-fpm` + 拡張 `mysql, curl, gd, mbstring, xml, zip, intl` |
| 補助 | `mariadb-client`（DB 待機用）, `curl`, `ca-certificates`, `procps` |
| wp-cli | `v2.12.0` の phar を `/usr/local/bin/wp` に配置（ビルド時に `wp --info` で検証） |
| プール設定 | `/etc/php/8.2/fpm/pool.d/www.conf` |
| CMD | `["/usr/sbin/php-fpm8.2", "-F"]` |

**nginx は入れません**（課題要件）。HTTP を話すのは nginx コンテナだけです。

#### `conf/www.conf` の要点

| 設定 | 値 | 理由 |
|---|---|---|
| `listen` | `0.0.0.0:9000` | UNIX ソケットではコンテナをまたげないため TCP |
| `user` / `group` | `www-data` | 実行ユーザー |
| `pm` | `dynamic` (`max_children=10`, `start_servers=3`, `min/max_spare=2/5`, `max_requests=500`) | VM 向けの控えめな値 |
| `clear_env` | `no` | コンテナ環境変数を PHP から見えるようにする |
| `catch_workers_output` | `yes` | ワーカーの出力を `docker logs` に流す |
| `access.log` | `/proc/self/fd/2` | 同上 |
| `php_admin_value[upload_max_filesize]` | `64M` | nginx の `client_max_body_size` と一致させる |
| `php_admin_value[post_max_size]` | `64M` | 同上 |
| `php_admin_value[memory_limit]` | `256M` | — |

#### entrypoint の処理フロー

```
1. /run/secrets/db_password を読む
2. . /run/secrets/credentials      ← WP_ADMIN_PASSWORD / WP_USER_PASSWORD を取り込む
3. 必須変数の存在チェック
4. 管理者名の検証: *admin* / *administrator* を含むなら即異常終了（課題要件の自衛）
5. DB 待機: mariadb -h $MYSQL_HOST … -e "SELECT 1" を最大30回、2秒間隔
      → 30回失敗したら明示的にエラー終了（無限ループにしない）
6. if [ ! -f /var/www/html/wp-config.php ]:      ← 初回のみ
      wp core download   --version=$WP_VERSION --locale=en_US
      wp config create   --dbname/--dbuser/--dbpass/--dbhost/--dbcharset/--dbcollate
                         --skip-check --extra-php <<PHP
                           X-Forwarded-Proto が https なら $_SERVER['HTTPS']='on'
                           FS_METHOD='direct'
                           DISALLOW_FILE_EDIT=true
                         PHP
      wp core install    --url=https://$DOMAIN_NAME --title --admin_user
                         --admin_password --admin_email --skip-email
      wp user create     $WP_USER $WP_USER_EMAIL --role --user_pass
      wp option update blogdescription / wp rewrite structure '/%postname%/'
   else: 「インストール済み、スキップ」とログ出力
7. chown -R www-data:www-data /var/www/html && mkdir -p /run/php
8. exec php-fpm8.2 -F          ← PID 1
```

`--extra-php` で書き込む定数はすべて `defined(...) or define(...)` で保護しています。wp-cli がこのブロックを2回評価するため、素の `define()` だと `Constant already defined` 警告が出ます。

作成されるユーザー:

| ユーザー | 権限 | 由来 |
|---|---|---|
| `chief_dreamer` | `administrator` | `WP_ADMIN_USER` / `WP_ADMIN_PASSWORD` |
| `cobb` | `author` | `WP_USER` / `WP_USER_PASSWORD` / `WP_USER_ROLE` |

### 5.3 nginx

#### イメージ

| 項目 | 内容 |
|---|---|
| ベース | `debian:bookworm` |
| 導入パッケージ | `nginx`（1.22 系）, `openssl`, `gettext-base`(envsubst), `curl`(ヘルスチェック) |
| テンプレート | `/etc/nginx/templates/default.conf.template` |
| CMD | `["nginx", "-g", "daemon off;"]` |

Dockerfile 内で `rm -f /etc/nginx/sites-enabled/default` と `rm -rf /var/www/html/*` を行います。後者は、nginx パッケージが置く `index.nginx-debian.html` が空の WordPress ボリュームへコピーされるのを防ぐためです。

#### entrypoint の処理フロー

```
1. DOMAIN_NAME 未設定チェック
2. 証明書が無ければ生成:
     openssl req -x509 -nodes -days 365 -newkey rsa:2048
       -subj "/C=FR/ST=Ile-de-France/L=Paris/O=42/OU=inception/CN=$DOMAIN_NAME"
       -addext "subjectAltName=DNS:$DOMAIN_NAME,DNS:www.$DOMAIN_NAME"
     → /etc/nginx/ssl/inception.{crt,key}（鍵は chmod 600）
3. envsubst '${DOMAIN_NAME}' でテンプレートを描画 → /etc/nginx/conf.d/default.conf
4. nginx -t で構文検証（失敗すればここで終了）
5. exec nginx -g 'daemon off;'      ← PID 1
```

`envsubst` は**置換対象を明示**しています（`envsubst '${DOMAIN_NAME}'`）。引数なしで実行すると `$uri` `$host` `$args` といった nginx 変数まで空文字に置換されてしまいます。

#### `conf/default.conf` の要点

| 設定 | 値 |
|---|---|
| `listen` | `443 ssl http2` / `[::]:443 ssl http2`（**80 番は一切開かない**） |
| `server_name` | `${DOMAIN_NAME}` |
| `ssl_certificate` / `_key` | `/etc/nginx/ssl/inception.crt` / `.key` |
| `ssl_protocols` | **`TLSv1.2 TLSv1.3` のみ** |
| `ssl_ciphers` | ECDHE + AES-GCM / CHACHA20-POLY1305（Mozilla の推奨構成） |
| `ssl_session_cache` | `shared:SSL:10m` |
| `root` / `index` | `/var/www/html` / `index.php index.html` |
| `client_max_body_size` | `64M` |
| 追加ヘッダ | `X-Frame-Options: SAMEORIGIN`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin` |

ロケーション:

| パス | 動作 |
|---|---|
| `/` | `try_files $uri $uri/ /index.php?$args;`（パーマリンク対応） |
| `\.php$` | `fastcgi_pass wordpress:9000;` + `SCRIPT_FILENAME` + `fastcgi_param HTTPS on;` + `fastcgi_read_timeout 300` |
| `= /wp-config.php` | `deny all;` |
| `~ /\.` | `deny all;`（ドットファイル） |
| 静的拡張子 | `expires 7d; access_log off;` |

`fastcgi_param HTTPS on;` により、TLS を終端しているのが nginx でも WordPress は自分が HTTPS 配信であると認識します。

---

## 6. Makefile 仕様

先頭で以下を定義します。

```make
LOGIN       ?= kkuramot
DOMAIN_NAME := $(LOGIN).42.fr
DATA_PATH   := /home/$(LOGIN)/data
COMPOSE     := docker compose -p inception -f srcs/docker-compose.yml --env-file srcs/.env
VOLUMES     := mariadb wordpress
```

### 6.1 ターゲット一覧

| ターゲット | 依存 | 動作 |
|---|---|---|
| `all`（既定） | `setup` | `$(COMPOSE) up --build -d` → `ps` |
| `build` | `setup` | `build`（起動しない） |
| `up` | `setup` | `up -d` |
| `down` | — | `down`（ボリュームは残す） |
| `stop` / `start` | — | 一時停止 / 再開 |
| `restart` | — | `down` → `all` |
| `re` | — | `fclean` → `all` |
| `setup` | `dirs env secrets` | 初期化一式（冪等） |
| `dirs` | — | `$(DATA_PATH)/{mariadb,wordpress}` を作成（必要なら sudo） |
| `env` | — | `srcs/.env` が無ければ `.env.example` から `__LOGIN__` を置換して生成 |
| `secrets` | — | 未作成のシークレットのみ `openssl rand` で生成し `chmod 600` |
| `hosts` | — | `/etc/hosts` に `127.0.0.1 $(DOMAIN_NAME)` を追記（重複時は何もしない） |
| `ps` / `status` | — | `ps` |
| `logs` | — | `logs -f --tail=100` |
| `clean` | `down` | さらに `down --rmi all --remove-orphans` |
| `fclean` | `clean` | 名前付きボリュームを削除し、`$(DATA_PATH)/*` を削除 |
| `prune` | `fclean` | `docker system prune -af --volumes` |
| `help` | — | ターゲット一覧を表示 |

### 6.2 削除の粒度

| ターゲット | コンテナ | イメージ | ボリューム | `/home/kkuramot/data` |
|---|:--:|:--:|:--:|:--:|
| `down` | 削除 | 残す | 残す | 残す |
| `clean` | 削除 | 削除 | 残す | 残す |
| `fclean` | 削除 | 削除 | 削除 | **削除** |
| `prune` | 削除 | 削除 | 削除 | **削除** + システム全体の prune |

### 6.3 ログイン名の切り替え

`LOGIN` は Makefile の1箇所だけで定義され、ドメイン名とデータパスの両方を決めます。

```sh
make LOGIN=wil          # wil.42.fr / /home/wil/data で構築
```

ただし `srcs/.env` が既にある場合は上書きしないため、切り替える際は `rm srcs/.env` してから実行してください。

---

## 7. 起動シーケンス

```
make
 └─ setup
     ├─ dirs    : /home/kkuramot/data/{mariadb,wordpress} を作成
     ├─ env     : srcs/.env を生成（__LOGIN__ → kkuramot）
     └─ secrets : secrets/*.txt を生成（既存は保持）
 └─ docker compose up --build -d
     ├─ 3イメージをビルド
     ├─ ネットワーク inception を作成
     ├─ 名前付きボリューム2つを作成（device 先が存在しないとここで失敗する）
     │
     ├─ mariadb 起動
     │    初回: mariadb-install-db → mariadbd --bootstrap（DB + ユーザー作成）
     │    exec mariadbd → healthcheck が通ると healthy
     │
     ├─ (healthy を待って) wordpress 起動
     │    DB 疎通を最大30回リトライ
     │    初回: wp core download → config create → core install → user create
     │    exec php-fpm -F
     │
     └─ nginx 起動
          自己署名証明書を生成 → envsubst で vhost 描画 → nginx -t → exec nginx
```

初回はイメージビルドと WordPress のダウンロードで数分、2回目以降は数十秒で全コンテナが healthy になります。

---

## 8. 通信経路とポート一覧

### 8.1 ホストに公開されるポート

| ポート | サービス | プロトコル | 備考 |
|---|---|---|---|
| `443` | nginx | HTTPS (TLSv1.2/1.3) | **唯一の入口** |

`80` 番は一切開きません（リダイレクトも設けません）。

### 8.2 ネットワーク内部のみの通信

| 経路 | ポート | プロトコル |
|---|---|---|
| nginx → wordpress | 9000 | FastCGI |
| wordpress → mariadb | 3306 | MySQL |

### 8.3 URL 一覧

| URL | 内容 |
|---|---|
| `https://kkuramot.42.fr/` | WordPress サイト |
| `https://kkuramot.42.fr/wp-admin/` | 管理画面 |

---

## 9. データ永続化仕様

### 9.1 ホスト側の実体

```
/home/kkuramot/data/
├── mariadb/     … MariaDB のデータディレクトリ（ibdata1, wordpress/ など）
└── wordpress/   … WordPress 本体・wp-content・アップロード
```

### 9.2 永続性の担保

永続性は「ボリュームがある」だけでは成立せず、**entrypoint が冪等であること**とセットで初めて成立します。

| サービス | 初期化のスキップ条件 |
|---|---|
| `mariadb` | `/var/lib/mysql/mysql` ディレクトリが存在する |
| `wordpress` | `/var/www/html/wp-config.php` が存在する |

これにより:

```sh
make down && make      # 記事・ユーザー・メディアすべて維持
make fclean && make    # すべて消去して新規インストール
```

---

## 10. セキュリティ仕様

| 項目 | 実装 |
|---|---|
| 通信の暗号化 | TLSv1.2 / TLSv1.3 のみ。それ以前のバージョンはハンドシェイクを拒否 |
| 平文 HTTP | ポート 80 を開かない |
| 証明書 | 自己署名（`CN=kkuramot.42.fr`, SAN 付き, RSA2048, 365日）。鍵は `chmod 600` |
| パスワードの保管 | Docker secrets（`/run/secrets/`）。イメージにも `docker inspect` にも現れない |
| Dockerfile 内のパスワード | **一切なし**（`ARG` や `ENV` にも渡さない） |
| リポジトリ | `secrets/*.txt` と `srcs/.env` を `.gitignore` で除外。追跡されるのは `.env.example`（機密なし）のみ |
| DB の露出 | 3306 はホストに公開せず `expose` のみ。root はネットワーク越しにログイン不可 |
| DB の root アカウント | `root@localhost`（パスワード付き）だけを残し、`mariadb-install-db` が作るパスワード無しの `root@127.0.0.1` / `root@::1` / `root@<hostname>` は初期化時に削除 |
| DB の不要な入口 | 匿名ユーザーと `test` データベースを初期化時に削除 |
| WordPress 管理者名 | `admin` / `administrator` を含む名前を entrypoint が拒否 |
| ファイル編集 | `DISALLOW_FILE_EDIT=true`（管理画面からのテーマ/プラグイン直接編集を禁止） |
| 設定ファイルの保護 | nginx が `wp-config.php` とドットファイルへのアクセスを `deny all` |
| 権限の降格 | php-fpm のワーカーは `www-data`、mariadbd は `mysql` |
| セキュリティヘッダ | `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy` |

---

## 11. 課題要件との対応表

| 要件 | 実装 | 該当箇所 |
|---|---|---|
| VM 上で実施 | 前提（本リポジトリは VM 内で `make` する） | — |
| 設定ファイルは `srcs/` 配下 | ✔ | `srcs/` |
| ルートに Makefile、compose 経由でビルド | ✔ | `Makefile` |
| `docker compose` を使用 | ✔ | `srcs/docker-compose.yml` |
| イメージ名 = サービス名 | ✔ `nginx:inception` など | compose の `image:` |
| 1サービス1コンテナ | ✔ 3コンテナ | compose |
| Alpine/Debian の安定版のひとつ前 | ✔ `debian:bookworm` | 全 Dockerfile |
| Dockerfile を自作（サービスごとに1つ） | ✔ 3個 | `srcs/requirements/**/Dockerfile` |
| 既製イメージの pull 禁止 | ✔ `FROM debian:bookworm` のみ | 全 Dockerfile |
| nginx は TLSv1.2/1.3 のみ | ✔ `ssl_protocols TLSv1.2 TLSv1.3;` | `nginx/conf/default.conf` |
| WordPress + php-fpm、nginx なし | ✔ | `wordpress/Dockerfile` |
| MariaDB のみ、nginx なし | ✔ | `mariadb/Dockerfile` |
| DB 用ボリューム | ✔ `mariadb` | compose `volumes:` |
| WordPress ファイル用ボリューム | ✔ `wordpress` | 同上 |
| 名前付きボリューム（bind mount 禁止） | ✔ `driver_opts` で実体のみ固定 | 同上 |
| 実体は `/home/login/data` | ✔ `${DATA_PATH}` | `.env` + Makefile |
| docker-network で接続 | ✔ `inception`（bridge） | compose `networks:` |
| クラッシュ時に再起動 | ✔ `restart: always` | compose |
| `network: host` / `links:` 禁止 | ✔ 不使用 | compose |
| 無限ループでの起動禁止 | ✔ 全 entrypoint が `exec`。待機は上限付き | 各 `tools/*.sh` |
| PID 1 のベストプラクティス | ✔ | 同上 |
| WordPress に2ユーザー、管理者名に admin 不可 | ✔ `chief_dreamer` / `cobb` | `wordpress/tools/*.sh` |
| ドメイン `login.42.fr` をローカル IP へ | ✔ `make hosts` | `Makefile` |
| `latest` タグ禁止 | ✔ | 全 Dockerfile / compose |
| Dockerfile にパスワードを書かない | ✔ | 全 Dockerfile |
| 環境変数の使用が必須 | ✔ `env_file: .env` | compose |
| `.env` の使用が必須 | ✔ `srcs/.env` | `.env.example` |
| Docker secrets 推奨 | ✔ 3つの secrets | compose `secrets:` |
| 認証情報を git に置かない | ✔ `.gitignore` | `.gitignore` |
| nginx が 443 の唯一の入口 | ✔ 公開ポートは 443 のみ | compose `ports:` |
| README.md（規定の項目） | ✔ 英語・比較4項目・AI 利用記述 | `README.md` |
| USER_DOC.md / DEV_DOC.md | ✔ | 各ファイル |

> ボーナス部分はこのブランチには含まれていません。

---

## 12. 動作検証手順と実測結果

### 12.1 検証コマンド

```sh
# 状態
make ps

# HTTPS 応答
curl -kI https://kkuramot.42.fr/

# TLS バージョン（1.2 と 1.3 は成功、1.1 以下は失敗すること）
openssl s_client -connect kkuramot.42.fr:443 -tls1_2 </dev/null
openssl s_client -connect kkuramot.42.fr:443 -tls1_3 </dev/null
openssl s_client -connect kkuramot.42.fr:443 -tls1_1 </dev/null   # 失敗が正しい

# ポート80が閉じていること
curl -I http://kkuramot.42.fr/                                    # 失敗が正しい

# WordPress ユーザー
docker exec -it wordpress wp --allow-root --path=/var/www/html user list

# DB の中身（MYSQL_HOST 環境変数があるため -h localhost の明示が必要）
docker exec -it mariadb mariadb -h localhost --protocol=socket \
    -u root -p"$(cat secrets/db_root_password.txt)" \
    -e "SELECT user,host FROM mysql.user; SHOW DATABASES;"

# ホスト側の実体
ls -l /home/kkuramot/data/wordpress /home/kkuramot/data/mariadb

# 永続性
make down && make      # 記事が残っていること
```

### 12.2 実測結果

Docker 28.5.1 上でゼロから構築して確認済み。

| 検証項目 | 結果 |
|---|---|
| 3イメージのクリーンビルド | 成功 |
| 空のデータディレクトリからの起動 | 全コンテナ healthy |
| `https://…/` | `200` |
| `https://…/wp-admin/` | `302`（ログイン画面へのリダイレクト） |
| TLSv1.2 | 接続成功（`ECDHE-RSA-AES256-GCM-SHA384`） |
| TLSv1.3 | 接続成功（`TLS_AES_256_GCM_SHA384`） |
| TLSv1.1 | `no protocols available`（拒否） |
| ポート 80 | 接続拒否 |
| 公開ポート | `nginx: 0.0.0.0:443->443/tcp` のみ |
| WordPress ユーザー | `chief_dreamer`(administrator) / `cobb`(author) |
| 永続性 | `down` → `up` 後も投稿が残存、両 entrypoint が初期化をスキップ |

### 12.3 構築中に発見・修正した不具合

| 事象 | 原因 | 対処 |
|---|---|---|
| DB もユーザーも作られない | `mariadb-server` パッケージがイメージ内 `/var/lib/mysql` を作り、空ボリュームへコピーされて「初期化済み」と誤判定 | Dockerfile で `rm -rf /var/lib/mysql/*` |
| WordPress ボリュームに `index.nginx-debian.html` が混入 | nginx パッケージの既定ページが空ボリュームへコピー | Dockerfile で `rm -rf /var/www/html/*` |
| nginx が `unknown directive "http2"` で起動失敗 | bookworm の nginx 1.22 に `http2 on;` は無い | `listen 443 ssl http2;` の旧記法へ |
| wp-cli が `Constant already defined` を出す | `--extra-php` のブロックが2回評価される | `defined(...) or define(...)` で保護 |
| パスワード無しで root ログインできる | `mariadb-install-db` が `root@127.0.0.1` / `root@::1` / `root@<hostname>` を無認証で作る | bootstrap で `localhost` 以外の root を削除 |

---

## 付録: よく使うコマンド

```sh
# ログ
docker logs -f wordpress
make logs

# コンテナに入る
docker exec -it wordpress bash
docker exec -it mariadb bash

# wp-cli
docker exec -it wordpress wp --allow-root --path=/var/www/html plugin list
docker exec -it wordpress wp --allow-root --path=/var/www/html user update cobb --user_pass='新しいパスワード'

# 単一サービスだけ再ビルド
docker compose -p inception -f srcs/docker-compose.yml --env-file srcs/.env \
    up -d --build nginx

# 実際に描画された nginx 設定を確認
docker exec -it nginx cat /etc/nginx/conf.d/default.conf
docker exec -it nginx nginx -t

# ボリューム
docker volume ls
docker volume inspect wordpress
```
