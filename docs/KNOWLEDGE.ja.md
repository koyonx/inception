# Inception ナレッジ集（日本語）

> 本書はこのプロジェクトを理解し、**評価（defense）で説明できるようになる**ための背景知識をまとめたものです。
> 実装そのものの仕様は [`SPEC.ja.md`](SPEC.ja.md) を参照してください。

---

## 目次

1. [Docker の基礎](#1-docker-の基礎)
2. [イメージ・レイヤー・Dockerfile](#2-イメージレイヤーdockerfile)
3. [PID 1 とシグナル — この課題の核心](#3-pid-1-とシグナル--この課題の核心)
4. [Docker ネットワーク](#4-docker-ネットワーク)
5. [ボリュームとデータ永続化](#5-ボリュームとデータ永続化)
6. [環境変数と Docker secrets](#6-環境変数と-docker-secrets)
7. [Docker Compose](#7-docker-compose)
8. [TLS / HTTPS](#8-tls--https)
9. [nginx と FastCGI](#9-nginx-と-fastcgi)
10. [php-fpm](#10-php-fpm)
11. [MariaDB](#11-mariadb)
12. [WordPress](#12-wordpress)
13. [Redis とオブジェクトキャッシュ](#13-redis-とオブジェクトキャッシュ)
14. [FTP（vsftpd）](#14-ftpvsftpd)
15. [cron とバックアップ](#15-cron-とバックアップ)
16. [評価（defense）想定質問集](#16-評価defense想定質問集)
17. [トラブルシューティング](#17-トラブルシューティング)
18. [用語集](#18-用語集)
19. [参考資料](#19-参考資料)

---

## 1. Docker の基礎

### 1.1 仮想マシンとコンテナの違い

| 観点 | 仮想マシン (VM) | コンテナ |
|---|---|---|
| 実体 | ハイパーバイザ上で**別のカーネルを起動**した仮想的なコンピュータ | ホストカーネル上で動く**ただのプロセス群** |
| 分離の仕組み | ハードウェア仮想化 | Linux カーネルの namespace + cgroup |
| 起動時間 | 数十秒〜数分（BIOS→カーネル→init） | ミリ秒〜秒（プロセスを起動するだけ） |
| ディスク使用量 | GB 単位（OS 一式） | MB〜数百 MB（差分レイヤー） |
| メモリ | 事前に固定割り当て | 使った分だけ（cgroup で上限設定可） |
| 別 OS の実行 | 可能（Linux 上で Windows など） | 不可（ホストと同じカーネル） |
| 分離の強度 | 強い（カーネルごと別） | 相対的に弱い（カーネルを共有） |

**この課題での位置づけ**: VM は「学校のマシンからプロジェクトを隔離する」層、Docker は「サービス同士を隔離する」層です。8サービスを VM 8台で作るのは現実的ではありませんが、コンテナ8個なら小さな VM 1台に収まります。

### 1.2 コンテナを支える Linux の機能

**namespace（名前空間）** — 「何が見えるか」を分離します。

| namespace | 分離するもの |
|---|---|
| `pid` | プロセス ID 空間（コンテナ内の PID 1 はホストでは別の PID） |
| `net` | ネットワークインターフェース・ルーティング・ポート |
| `mnt` | マウントポイント（ファイルシステムの見え方） |
| `uts` | ホスト名 |
| `ipc` | プロセス間通信 |
| `user` | UID / GID のマッピング |

**cgroup（コントロールグループ）** — 「どれだけ使えるか」を制限します（CPU・メモリ・I/O・プロセス数）。

**capabilities / seccomp / AppArmor** — root 権限を細分化し、危険なシステムコールを遮断します。

> つまり「コンテナ」という単一のカーネル機能があるのではなく、上記を組み合わせて**プロセスに檻をかぶせたもの**がコンテナです。

---

## 2. イメージ・レイヤー・Dockerfile

### 2.1 レイヤー構造

イメージは**読み取り専用レイヤーの積み重ね**です。`RUN` / `COPY` / `ADD` の各命令が1レイヤーを作ります。コンテナ起動時にはその上に**書き込み可能レイヤー**が1枚乗り、変更はそこに記録されます（copy-on-write）。

```
┌──────────────────────────┐  ← コンテナの書き込み層（削除すると消える）
├──────────────────────────┤  ← COPY tools/entrypoint.sh
├──────────────────────────┤  ← RUN apt-get install …
└──────────────────────────┘  ← FROM debian:bookworm
```

このため:

- **一度書いたものは消えない**: `RUN apt-get install`、次の行で `RUN rm` しても前のレイヤーにファイルは残る。だから `apt-get install` と `rm -rf /var/lib/apt/lists/*` は**同じ RUN にまとめる**。
- **秘密情報を `RUN` や `ENV` に書くと `docker history` で見える**。だからパスワードは実行時に secrets から読む。

本プロジェクトの典型例:

```dockerfile
RUN apt-get update && \
    apt-get install -y --no-install-recommends nginx openssl gettext-base curl && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*
```

`--no-install-recommends` は推奨パッケージを入れず、イメージを小さく保ちます。

### 2.2 ENTRYPOINT と CMD

| 記法 | 意味 |
|---|---|
| `ENTRYPOINT ["/path/script.sh"]` | 常に実行される本体 |
| `CMD ["nginx", "-g", "daemon off;"]` | ENTRYPOINT に渡される**既定の引数** |

本プロジェクトは全サービスでこの組み合わせを使い、entrypoint の末尾を `exec "$@"` にしています。

```sh
# 初期化処理 …
exec "$@"        # ← CMD の内容（例: nginx -g 'daemon off;'）に置き換わる
```

こうすると、**初期化スクリプトは残らず、本体プロセスがそのまま PID 1 になります**。

### 2.3 exec 形式と shell 形式

| 記法 | 実際の起動 | PID 1 |
|---|---|---|
| `CMD ["nginx", "-g", "daemon off;"]`（exec 形式） | `nginx` を直接 exec | **nginx** |
| `CMD nginx -g 'daemon off;'`（shell 形式） | `/bin/sh -c "nginx …"` | **sh**（nginx は子プロセス） |

shell 形式では `sh` が PID 1 になり、`docker stop` の SIGTERM が nginx に届きません。本プロジェクトは全て exec 形式を使います。

### 2.4 `.dockerignore`

ビルドコンテキスト（Docker デーモンに送られるファイル一式）から不要物を除外します。本プロジェクトは「全部拒否してから必要なものだけ許可」する安全側の書き方です。

```
*
!Dockerfile
!conf
!conf/**
!tools
!tools/**
```

これにより、うっかり `secrets/` などが混入することを防げます。

### 2.5 なぜ `latest` タグが禁止か

`latest` は「最新」を意味する**ただのタグ名**で、指す中身は時間とともに変わります。今日ビルドしたイメージと明日ビルドしたイメージが別物になり、再現性が失われます。本プロジェクトは:

- ベースイメージ: `debian:bookworm`（コードネーム固定）
- 自作イメージ: `nginx:inception` のように独自タグ
- ダウンロードするもの: WordPress `6.7.1`、wp-cli `2.12.0`、Adminer `4.8.1` とバージョン固定

---

## 3. PID 1 とシグナル — この課題の核心

### 3.1 PID 1 の特別扱い

Linux では PID 1 のプロセスに2つの特殊な役割があります。

1. **孤児プロセスの引き取り（reaping）**: 親が終了したプロセスは PID 1 の子になり、PID 1 が `wait()` してゾンビを回収する義務を負う。
2. **シグナルの既定動作が無効**: 通常のプロセスは SIGTERM を受けると既定で終了しますが、**PID 1 はハンドラを登録していない限り SIGTERM を無視します**。

### 3.2 `docker stop` で起きること

```
docker stop nginx
  ├─ PID 1 に SIGTERM を送る
  ├─ 既定10秒待つ
  └─ まだ生きていれば SIGKILL（強制終了）
```

PID 1 が SIGTERM を無視するプロセス（例: `sh`、`tail -f`）だと、毎回10秒待たされた挙句に強制終了されます。データベースであれば**書き込み途中で殺される**ことになり、破損の原因になります。

対して nginx・mariadbd・php-fpm・redis-server・vsftpd・cron は SIGTERM ハンドラを実装しており、受け取ると接続を捌き切ってから安全に終了します（graceful shutdown）。だから**本体を PID 1 にする**必要があります。

### 3.3 なぜ `tail -f` / `sleep infinity` / `while true` が禁止なのか

これらは「コンテナをとりあえず生かしておく」ための擬似デーモンです。

```dockerfile
# ❌ 絶対にやらない
CMD service nginx start && tail -f /var/log/nginx/access.log
```

このとき:

- PID 1 は `tail`。nginx は `service` が起こしたバックグラウンドプロセス。
- `docker stop` の SIGTERM は `tail` に飛び、nginx には届かない → 強制終了される。
- nginx が異常終了しても `tail` は生き続けるので、**コンテナは "Up" のまま中身が死ぬ**。`restart: always` も発動しない。
- ヘルスチェックが無ければ誰も気づかない。

つまり禁止事項は「行儀の問題」ではなく、**コンテナの死活監視と安全停止を壊す**から禁止されています。

### 3.4 待機ループは「無限」でなければよい

依存サービスの起動待ちは現実に必要です。本プロジェクトは**回数上限つき**にしています。

```sh
i=1
while [ "$i" -le 30 ]; do
	if mariadb -h "$MYSQL_HOST" … -e "SELECT 1" > /dev/null 2>&1; then
		break
	fi
	[ "$i" -eq 30 ] && { echo "FATAL: database unreachable" >&2; exit 1; }
	i=$((i + 1))
	sleep 2
done
```

- 最大60秒で諦めて**明示的に異常終了**する（`restart: always` が再試行してくれる）。
- `while true` と違い、永久に無言で待ち続けることがない。
- そもそも compose 側で `depends_on: condition: service_healthy` を使い、DB が healthy になるまで起動しない設計にしてあるため、このループは保険です。

### 3.5 デーモン化を止める設定一覧

各ソフトウェアには「フォアグラウンドで動く」設定があります。

| サービス | 設定 |
|---|---|
| nginx | `nginx -g "daemon off;"` |
| php-fpm | `php-fpm8.2 -F`（`--nodaemonize`） |
| MariaDB | `mariadbd` を直接起動（`mysqld_safe` はラッパーなので使わない） |
| Redis | `redis.conf` の `daemonize no` |
| vsftpd | `-obackground=NO` または conf の `background=NO` |
| cron | `cron -f` |
| PHP ビルトインサーバ | `php -S`（元々フォアグラウンド） |

---

## 4. Docker ネットワーク

### 4.1 ネットワークドライバ

| ドライバ | 特徴 |
|---|---|
| `bridge`（既定） | 仮想スイッチを作り、各コンテナに専用 IP を割り当てる |
| `host` | ホストのネットワークスタックを直接使う（分離なし） |
| `none` | ネットワークなし |
| `overlay` | 複数ホストにまたがる（Swarm/K8s 用） |

### 4.2 ユーザー定義 bridge と内蔵 DNS

`docker network create` で作ったネットワーク（compose の `networks:` も同様）では、**Docker の内蔵 DNS サーバ `127.0.0.11`** が動きます。これによりコンテナ名・サービス名がそのままホスト名として解決されます。

```
wordpress コンテナ内で "mariadb" を名前解決
  → 127.0.0.11 が応答 → 172.19.0.x（mariadb コンテナの IP）
```

IP アドレスをハードコードする必要がなく、コンテナを作り直して IP が変わっても壊れません。

> **補足**: 既定の `bridge` ネットワーク（`docker0`）には DNS がありません。だから昔は `--link` が必要でした。ユーザー定義ネットワークの登場で `--link` は非推奨（legacy）になり、この課題でも禁止されています。

### 4.3 `expose` と `ports` の違い

| 記法 | 意味 |
|---|---|
| `expose: ["3306"]` | ドキュメント的宣言。**ホストには公開されない**。同一ネットワークのコンテナからは元々アクセス可能 |
| `ports: ["443:443"]` | ホストのポートをコンテナへ**転送する**（外部から到達可能になる） |

本プロジェクトでは `nginx` だけが `ports: ["443:443"]` を持ち、他は `expose` のみです（FTP はボーナス規定により追加公開）。

### 4.4 なぜ `network: host` が禁止か

`network_mode: host` にすると:

- コンテナがホストのネットワーク名前空間をそのまま使う → **ネットワークの分離が消える**。
- コンテナが開いたポートは即ホストのポート。`nginx が唯一の入口` という要件を技術的に保証できない。
- サービス名での名前解決ができない（全部 `localhost`）。
- 同じポートを使うコンテナを複数動かせない（MariaDB を2つ動かせないなど）。

### 4.5 nginx の遅延名前解決

nginx は起動時に `proxy_pass http://adminer:8080;` のホスト名を解決しようとし、解決できないと**起動に失敗**します。ボーナス無効時にこれが起きないよう、変数経由にしています。

```nginx
resolver 127.0.0.11 ipv6=off valid=10s;
set $adminer_upstream http://adminer:8080;
rewrite ^/adminer/(.*)$ /$1 break;
proxy_pass $adminer_upstream;
```

`proxy_pass` に変数を使うと解決がリクエスト時に遅延します。ただし**変数形式では location のプレフィックスが自動で剥がれない**ため、`rewrite … break` でパスを整える必要があります（`/adminer/foo` → upstream には `/foo` を渡す）。

---

## 5. ボリュームとデータ永続化

### 5.1 3種類のマウント

| 種類 | 記法 | 特徴 |
|---|---|---|
| **名前付きボリューム** | `wordpress:/var/www/html` | Docker が管理。`docker volume ls` に出る。`down` で消えない。実体は `/var/lib/docker/volumes/…` |
| **バインドマウント** | `/host/path:/var/www/html` | ホストの任意パスを直結。Docker の管理対象外。ホストの構成に依存 |
| **tmpfs** | `--tmpfs /tmp` | メモリ上。コンテナ終了で消える |

### 5.2 名前付きボリュームが選ばれる理由

| 観点 | 名前付きボリューム | バインドマウント |
|---|---|---|
| 管理 | Docker のオブジェクト（作成・一覧・検査・削除が可能） | ただのパス。Docker は関知しない |
| 移植性 | ホストのディレクトリ構成に依存しない | 依存する（パスが無ければ失敗） |
| 権限 | 初回にイメージ側の所有者・パーミッションを引き継ぐ | ホストの UID/GID がそのまま見える |
| 初期データ | **空なら**イメージの中身がコピーされる（copy-up） | コピーされない。イメージ側の内容は隠れる |
| バックアップ | `docker run --rm -v vol:/data …` で扱える | ホストで直接扱う |

### 5.3 この課題特有の要求と `driver_opts`

課題は「名前付きボリュームを使え」「ただしデータは `/home/login/data` に置け」という一見矛盾した要求をします。これを満たすのが `local` ドライバの `driver_opts` です。

```yaml
volumes:
  wordpress:
    name: wordpress
    driver: local
    driver_opts:
      type: none        # ファイルシステムタイプを指定しない
      o: bind           # bind マウントとして扱う
      device: ${DATA_PATH}/wordpress   # 実体のパス
```

- **オブジェクトとしては名前付きボリューム**: サービスは `wordpress:/var/www/html` と名前で参照し、`docker volume inspect wordpress` で情報が取れる。
- **実体だけがホストの指定パス**: `/home/kkuramot/data/wordpress`。

サービス定義には一切バインドマウント記法（`/host:/container`）が出てきません。

> `device` のディレクトリが存在しないとボリューム作成に失敗します。だから `make setup` の `dirs` ターゲットで先にディレクトリを作ります。

### 5.4 copy-up の罠（本プロジェクトで実際に踏んだ）

空の名前付きボリュームをマウントすると、Docker は**イメージ側のそのパスの中身をボリュームへコピー**します。便利な機能ですが、次の問題を起こしました。

| ケース | 何が起きたか | 対処 |
|---|---|---|
| `mariadb` | `apt-get install mariadb-server` がイメージ内 `/var/lib/mysql` にシステムテーブルを作成 → 空ボリュームにコピーされる → entrypoint が「初期化済み」と誤判定し、DB もユーザーも作られない | Dockerfile 末尾で `rm -rf /var/lib/mysql/*` |
| `nginx` | nginx パッケージの `/var/www/html/index.nginx-debian.html` が WordPress ボリュームにコピーされる | Dockerfile 末尾で `rm -rf /var/www/html/*` |

**教訓**: ボリュームをマウントする予定のパスは、イメージ側では**空にしておく**。

### 5.5 永続性は「ボリューム + 冪等な初期化」で成立する

ボリュームがあっても、entrypoint が毎回 `wp core install` を実行したら意味がありません。本プロジェクトは:

| サービス | スキップ条件 |
|---|---|
| mariadb | `/var/lib/mysql/mysql` が存在する |
| wordpress | `/var/www/html/wp-config.php` が存在する |

これで `make down && make` を何度繰り返してもデータが保たれます。

---

## 6. 環境変数と Docker secrets

### 6.1 環境変数の弱点

環境変数は設定を渡す標準的な手段ですが、秘密情報には向きません。

- `docker inspect <container>` で丸見え。
- `/proc/<pid>/environ` を読めば同じ名前空間の他プロセスからも見える。
- **子プロセスに自動的に継承される**。意図しないプログラムに渡る。
- クラッシュダンプやログに紛れ込みやすい。

### 6.2 Docker secrets

secrets は**ファイルとしてマウントされる秘密情報**です。

```yaml
secrets:
  db_password:
    file: ../secrets/db_password.txt
services:
  mariadb:
    secrets: [db_password]     # → /run/secrets/db_password（読み取り専用）
```

利点:

- イメージに焼き込まれない（`docker history` に出ない）。
- `docker inspect` に値が出ない。
- 宣言したコンテナからしか見えない。
- 環境変数と違って子プロセスに自動継承されない。
- Swarm では暗号化されて配布される（Compose 単体ではローカルファイルのマウント相当）。

### 6.3 本プロジェクトの使い分け

| 種別 | 例 | 置き場所 |
|---|---|---|
| 設定（非機密） | `DOMAIN_NAME`, `MYSQL_DATABASE`, `MYSQL_USER`, `WP_ADMIN_USER`, `REDIS_HOST` | `srcs/.env` |
| 秘密情報 | DB root / DB user / FTP / WordPress の各パスワード | `secrets/*.txt` |

どちらも `.gitignore` で除外し、追跡されるのは機密を含まない `srcs/.env.example` だけです。

> **なぜ `.env` まで git 除外するのか**: 現状の `.env` に秘密情報は入っていませんが、「`.env` は追跡しない」というルールを徹底しておけば、後日うっかりパスワードを書き足しても事故になりません。テンプレートを別に置くことで、必要な変数一覧はリポジトリ上で分かります。

---

## 7. Docker Compose

### 7.1 役割

複数コンテナの構成（イメージ、ネットワーク、ボリューム、依存関係、環境変数、再起動ポリシー）を**1つの YAML に宣言**し、`docker compose up` で一括構築します。手で `docker run` を8回打つのに比べ、再現性・可読性・変更容易性が段違いです。

### 7.2 `.env` の読み込み順序

Compose は2つの用途で環境変数を扱います。混同しやすいので注意。

| 用途 | 仕組み |
|---|---|
| **YAML 内の `${VAR}` 展開** | compose ファイルと同じディレクトリの `.env`（または `--env-file`）を読む |
| **コンテナへの注入** | サービスの `env_file:` / `environment:` |

本プロジェクトは両方に `.env` を使っています（`${DATA_PATH}` の展開と、`env_file: .env` による注入）。

### 7.3 依存関係とヘルスチェック

```yaml
depends_on:
  mariadb:
    condition: service_healthy
```

`depends_on` を条件なしで書くと「コンテナが起動した」ことしか保証しません（プロセスが受付可能になったかは分からない）。`condition: service_healthy` と `healthcheck` を組み合わせて初めて「使える状態になるまで待つ」が実現します。

| condition | 意味 |
|---|---|
| `service_started` | コンテナが起動した（既定） |
| `service_healthy` | ヘルスチェックが通った |
| `service_completed_successfully` | 正常終了した（初期化ジョブ用） |

### 7.4 再起動ポリシー

| ポリシー | 挙動 |
|---|---|
| `no` | 再起動しない（既定） |
| `on-failure[:N]` | 異常終了時のみ再起動 |
| `always` | 常に再起動。Docker デーモン再起動時も起動する |
| `unless-stopped` | `always` と同様だが、手動停止した状態は維持 |

課題は「クラッシュ時に再起動すること」を要求しているため `always` を採用しています。

### 7.5 プロファイル

```yaml
redis:
  profiles: ["bonus"]
```

`--profile bonus` を付けたときだけ作成されるサービスです。これにより `make`（必須+ボーナス）と `make mandatory`（必須のみ）を同じ compose ファイルで切り替えられます。

> **注意**: プロファイル無効なサービスに対して `depends_on` すると定義エラーになります。そのため nginx はボーナスコンテナに依存させず、DNS の遅延解決で対応しています。

---

## 8. TLS / HTTPS

### 8.1 TLS ハンドシェイクの概要

```
Client                                Server
  │  ClientHello（対応 TLS バージョン・暗号スイート一覧）
  ├───────────────────────────────────────►
  │                        ServerHello（採用するバージョン・暗号スイート）
  │                        Certificate（サーバ証明書）
  │◄───────────────────────────────────────
  │  鍵交換（ECDHE など）→ 共通鍵を生成
  ├───────────────────────────────────────►
  │  以降は共通鍵による暗号化通信（AES-GCM など）
```

TLS が提供するのは3つ: **機密性**（盗聴防止）・**完全性**（改竄検知）・**認証**（相手が本物か）。

### 8.2 TLS 1.2 と 1.3

| 観点 | TLS 1.2 | TLS 1.3 |
|---|---|---|
| 公開年 | 2008 | 2018 |
| ハンドシェイク往復 | 2-RTT | **1-RTT**（再接続は 0-RTT も可能） |
| 暗号スイート | 多数。RC4・3DES・CBC など脆弱な選択肢も残る | 5種類のみ（AEAD 限定） |
| 鍵交換 | RSA 鍵交換も可能（前方秘匿性なし） | **必ず (EC)DHE**（前方秘匿性あり） |
| 旧式アルゴリズム | 使えてしまう | 仕様から削除 |

TLS 1.0 / 1.1 は既に非推奨（RFC 8996 で廃止）で、脆弱性（BEAST、POODLE 等）や古い MAC 方式の問題を抱えます。だから課題は 1.2 / 1.3 のみを要求します。

### 8.3 nginx での設定

```nginx
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:…;
ssl_prefer_server_ciphers off;
```

- `ssl_protocols` に列挙したもの**以外は拒否**されます。TLS 1.1 で接続しようとすると `no protocols available` になります。
- 暗号スイートは Mozilla の Intermediate 相当（ECDHE による前方秘匿性 + AEAD）。
- `ssl_prefer_server_ciphers off` は TLS 1.3 時代の推奨（クライアント側の性能特性を尊重する）。

### 8.4 自己署名証明書

```sh
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout inception.key -out inception.crt \
  -subj "/C=FR/ST=Ile-de-France/L=Paris/O=42/OU=inception/CN=kkuramot.42.fr" \
  -addext "subjectAltName=DNS:kkuramot.42.fr,DNS:www.kkuramot.42.fr"
```

| オプション | 意味 |
|---|---|
| `-x509` | CSR ではなく自己署名証明書を直接出力 |
| `-nodes` | 秘密鍵にパスフレーズをかけない（起動を自動化するため） |
| `-newkey rsa:2048` | 秘密鍵も同時に生成 |
| `-subj` | 対話入力を省略。`CN` はドメイン名 |
| `-addext subjectAltName` | 現代のブラウザは CN ではなく **SAN** を見るため必須 |

自己署名なので信頼された CA の署名がなく、ブラウザは警告を出します。これは**暗号化が弱いのではなく、身元を第三者が保証していない**という意味です。ローカル開発では例外承認して進みます。

### 8.5 なぜポート 80 を開かないのか

「80 → 443 へリダイレクト」は一般的ですが、課題は「**443 のみ**が入口」と明記しています。80 を開けば、そこに来た最初のリクエストは平文であり、要件を厳密には満たしません。本プロジェクトは `listen 80` を書かず、80 番は完全に閉じています。

---

## 9. nginx と FastCGI

### 9.1 CGI → FastCGI

| 方式 | 動作 |
|---|---|
| CGI | リクエストごとにプロセスを fork/exec。毎回 PHP を起動するため遅い |
| **FastCGI** | 常駐プロセスに**バイナリプロトコル**でリクエストを渡す。プロセス再利用で高速 |
| mod_php | Web サーバのプロセス内で PHP を実行（Apache 方式）。分離できない |

FastCGI は「Web サーバ」と「アプリケーション実行環境」を分離できるため、**nginx コンテナと WordPress コンテナを分ける**という課題要件と自然に噛み合います。

### 9.2 nginx 側の設定

```nginx
location ~ \.php$ {
    try_files      $uri =404;                 # 存在しない .php を php-fpm に渡さない
    include        fastcgi_params;            # 標準の FastCGI パラメータ群
    fastcgi_pass   wordpress:9000;            # 別コンテナの php-fpm へ
    fastcgi_index  index.php;
    fastcgi_param  SCRIPT_FILENAME $document_root$fastcgi_script_name;
    fastcgi_param  PATH_INFO       $fastcgi_path_info;
    fastcgi_param  HTTPS           on;        # TLS 終端の内側であることを PHP に伝える
    fastcgi_read_timeout 300;
}
```

| ポイント | 説明 |
|---|---|
| `try_files $uri =404` | 存在しないパスを PHP に渡すと、任意コード実行につながる設定ミス（`cgi.fix_pathinfo`）を突かれる恐れがある。先に 404 で弾く |
| `SCRIPT_FILENAME` | php-fpm 側が「どのファイルを実行するか」を決める最重要パラメータ。`$document_root$fastcgi_script_name` で組み立てる |
| `fastcgi_param HTTPS on` | nginx が TLS を終端しているため、PHP からは平文 HTTP に見える。これを渡さないと WordPress が管理画面で無限リダイレクトすることがある |

**nginx と php-fpm はドキュメントルートを共有する必要があります**。`SCRIPT_FILENAME` はパスを渡すだけなので、php-fpm 側に同じファイルが見えていなければなりません。だから両コンテナが `wordpress` ボリュームをマウントしています（nginx は読み取り専用）。

### 9.3 `try_files` とパーマリンク

```nginx
location / {
    try_files $uri $uri/ /index.php?$args;
}
```

`/2026/08/hello-world/` のような URL は実ファイルではありません。ファイル → ディレクトリ → 見つからなければ `index.php` に投げる、という順で試すことで WordPress のパーマリンクが機能します。

### 9.4 リバースプロキシ

```nginx
proxy_pass         http://adminer:8080;
proxy_set_header   Host              $host;
proxy_set_header   X-Real-IP         $remote_addr;
proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header   X-Forwarded-Proto https;
```

`X-Forwarded-*` はバックエンドに「本来のクライアント情報」を伝えるための慣習的ヘッダです。これがないとバックエンドは全アクセスを nginx からのものだと認識します。

---

## 10. php-fpm

### 10.1 FPM とは

**FastCGI Process Manager**。PHP のワーカープロセスを管理し、FastCGI リクエストを捌きます。

```
php-fpm マスタープロセス（PID 1）
 ├── worker（www-data）
 ├── worker（www-data）
 └── worker（www-data）
```

マスターは設定の読み込み・ワーカーの起動と監視・シグナル処理を担当し、実際のリクエストはワーカーが処理します。

### 10.2 プロセスマネージャの種類

| `pm` | 挙動 | 向き |
|---|---|---|
| `static` | 常に `pm.max_children` 個 | 高負荷・メモリに余裕がある環境 |
| `dynamic` | 負荷に応じて増減（本プロジェクトはこれ） | 一般的 |
| `ondemand` | 必要になってから起動 | 低トラフィック・省メモリ |

本プロジェクトの値（VM 前提の控えめな設定）:

```ini
pm = dynamic
pm.max_children      = 10   ; 同時に存在できるワーカー上限
pm.start_servers     = 3    ; 起動時のワーカー数
pm.min_spare_servers = 2    ; アイドルワーカーの下限
pm.max_spare_servers = 5    ; アイドルワーカーの上限
pm.max_requests      = 500  ; N リクエストごとにワーカーを再生成（メモリリーク対策）
```

### 10.3 なぜ UNIX ソケットでなく TCP か

php-fpm は既定で `/run/php/php8.2-fpm.sock` を使いますが、**UNIX ソケットは同じファイルシステムを共有するプロセス間でしか使えません**。nginx と php-fpm は別コンテナなので、TCP で待ち受けます。

```ini
listen = 0.0.0.0:9000
```

9000 はホストに公開しないため、外部から直接叩かれることはありません。

### 10.4 `clear_env = no`

php-fpm は既定でコンテナの環境変数をワーカーから隠します（`clear_env = yes`）。本プロジェクトは `wp-config.php` の中で `getenv('REDIS_HOST')` などを使うため `no` にしています。

---

## 11. MariaDB

### 11.1 初期化の3段階

```
1. mariadb-install-db   … データディレクトリにシステムテーブル（mysql スキーマ）を作る
2. mariadbd --bootstrap … 単発モードで SQL を流す（DB 作成・ユーザー作成・権限付与）
3. exec mariadbd        … 通常のサーバとして起動（PID 1）
```

`--bootstrap` は「標準入力から SQL を読み、実行し終えたら終了する」モードです。ネットワークも待ち受けません。これを使うことで、

- 「一時的にサーバを起動 → `sleep` で待つ → SQL 実行 → 停止 → 本起動」
という**ループとスリープだらけの手順を完全に回避**できます。

### 11.2 権限設計

```sql
ALTER USER 'root'@'localhost' IDENTIFIED BY '<root password>';
DELETE FROM mysql.global_priv WHERE User='';        -- 匿名ユーザーを削除
DROP DATABASE IF EXISTS test;                        -- テスト用 DB を削除
CREATE DATABASE IF NOT EXISTS `wordpress` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'wp_user'@'%' IDENTIFIED BY '<db password>';
GRANT ALL PRIVILEGES ON `wordpress`.* TO 'wp_user'@'%';
FLUSH PRIVILEGES;
```

| 設計 | 理由 |
|---|---|
| `root@'localhost'` のみ | ネットワーク越しの root ログインを不可能にする |
| `wp_user@'%'` | コンテナの IP は毎回変わるためホスト指定はワイルドカード |
| 権限は `wordpress`.* のみ | 最小権限。他 DB には触れない |
| 匿名ユーザー削除・test DB 削除 | 既定で作られる不要な入口を塞ぐ |

> MariaDB 10.4 以降、ユーザー情報は `mysql.user`（ビュー）ではなく **`mysql.global_priv`** テーブルが実体です。

### 11.3 `utf8mb4` を使う理由

MySQL/MariaDB の `utf8` は**最大3バイト**しか扱えず、絵文字（4バイト）を保存できません。`utf8mb4` が本来の UTF-8 です。照合順序は `utf8mb4_unicode_ci`（大文字小文字を区別しない Unicode 準拠の比較）。

### 11.4 `MYSQL_HOST` 環境変数の罠

MySQL/MariaDB のクライアントは**環境変数 `MYSQL_HOST` を既定の接続先として読みます**。本プロジェクトは `env_file` により全コンテナに `MYSQL_HOST=mariadb` が入るため、mariadb コンテナ内で

```sh
docker exec mariadb mariadb -u root -p…      # ← 自分自身へ TCP 接続してしまう
```

とすると `root@'%'` が存在しないため拒否されます。ソケット経由で入りたいときは明示します。

```sh
docker exec -it mariadb mariadb -h localhost --protocol=socket -u root -p"$(cat secrets/db_root_password.txt)"
```

### 11.5 論理バックアップと `--single-transaction`

`mariadb-dump` は SQL 文の形でデータを書き出す**論理バックアップ**です。`--single-transaction` を付けると、InnoDB の MVCC を利用して**テーブルをロックせずに一貫したスナップショット**を取得できます（サービスを止めずにバックアップできる）。

---

## 12. WordPress

### 12.1 構成要素

| 要素 | 役割 |
|---|---|
| コアファイル | `/var/www/html` 配下の PHP 一式 |
| `wp-config.php` | DB 接続情報・セキュリティキー・各種定数 |
| データベース | 投稿・ユーザー・設定・メタ情報 |
| `wp-content/` | テーマ・プラグイン・アップロードファイル |

**「コアファイル」と「データベース」の両方が揃って初めてサイトが復元できます**。だからボリュームは2つ必要です。

### 12.2 wp-cli による自動セットアップ

ブラウザの5分インストールを使わず、CLI で完結させています。

| コマンド | 役割 |
|---|---|
| `wp core download --version=6.7.1` | 指定バージョンのコアを取得 |
| `wp config create --dbname … --extra-php` | `wp-config.php` を生成（追加の PHP コードも埋め込める） |
| `wp core install --url --title --admin_user …` | DB にテーブルを作り、管理者を作成 |
| `wp user create <name> <email> --role --user_pass` | 2人目のユーザーを作成 |
| `wp plugin install redis-cache --activate` | プラグイン導入 |
| `wp redis enable` | オブジェクトキャッシュのドロップインを配置 |

`--allow-root` は root で実行するため必要です（コンテナ内では通常 root）。

### 12.3 リバースプロキシ配下での HTTPS 判定

nginx が TLS を終端しているため、PHP には平文の HTTP リクエストとして届きます。WordPress はこれを見て「サイト URL は https なのにアクセスは http だ」と判断し、リダイレクトループを起こすことがあります。対策は2重に入れてあります。

1. nginx 側: `fastcgi_param HTTPS on;`
2. `wp-config.php` 側:

```php
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO'])
    && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    $_SERVER['HTTPS'] = 'on';
}
```

### 12.4 埋め込んだセキュリティ定数

| 定数 | 効果 |
|---|---|
| `FS_METHOD = 'direct'` | プラグイン更新時に FTP 認証を求めず直接ファイル操作する |
| `DISALLOW_FILE_EDIT = true` | 管理画面からのテーマ/プラグイン直接編集を禁止（乗っ取り時の被害を限定） |
| `WP_REDIS_HOST` / `WP_REDIS_PORT` | オブジェクトキャッシュの接続先 |
| `WP_CACHE_KEY_SALT` | キャッシュキーの名前空間（複数サイトでの衝突防止） |

これらは `defined(...) or define(...)` で保護しています。wp-cli がこのブロックを2回評価するため、素の `define()` では `Constant already defined` 警告が出るからです。

### 12.5 管理者名の制約

課題は管理者名に `admin` / `administrator` を含めることを禁じています。攻撃者が真っ先に試すユーザー名だからです（ブルートフォースの探索空間を1つ減らしてしまう）。entrypoint 側でも検査しています。

```sh
case "$WP_ADMIN_USER" in
	*[Aa]dmin*|*[Aa]dministrator*)
		echo "FATAL: WP_ADMIN_USER must not contain 'admin'" >&2; exit 1 ;;
esac
```

---

## 13. Redis とオブジェクトキャッシュ

### 13.1 WordPress のキャッシュ階層

| 種類 | 内容 | 永続性 |
|---|---|---|
| オブジェクトキャッシュ | DB クエリ結果・オプション値などを保持 | 既定はリクエスト内のみ（**非永続**） |
| ページキャッシュ | 生成済み HTML を保持 | プラグイン依存 |
| ブラウザキャッシュ | 静的ファイル | `expires` ヘッダ |

WordPress の既定のオブジェクトキャッシュは**リクエストが終わると消えます**。Redis を外部ストアにすると、リクエストをまたいでキャッシュが効き、DB へのクエリ数が大きく減ります。

### 13.2 導入の仕組み

`redis-cache` プラグインは `wp-content/object-cache.php`（ドロップイン）を配置します。WordPress はこのファイルがあると、既定の実装の代わりにこちらを使います。PHP 側には `php8.2-redis` 拡張（PhpRedis）が必要です。

確認:

```sh
docker exec -it wordpress wp --allow-root --path=/var/www/html redis status
# Status: Connected / Client: PhpRedis / Drop-in: Valid
docker exec -it redis redis-cli dbsize
```

### 13.3 追い出しポリシー

```
maxmemory 256mb
maxmemory-policy allkeys-lru
```

| ポリシー | 挙動 |
|---|---|
| `noeviction` | 上限到達で書き込みエラー（キャッシュ用途には不向き） |
| `allkeys-lru` | 最も長く使われていないキーから削除（**キャッシュ用途の定番**） |
| `volatile-lru` | TTL 付きのキーのみ LRU で削除 |

キャッシュは「消えても再計算できるデータ」なので、上限を決めて古いものから捨てるのが正解です。

---

## 14. FTP（vsftpd）

### 14.1 アクティブとパッシブ

| モード | データ接続の向き |
|---|---|
| アクティブ | **サーバ → クライアント**（クライアントの待ち受けポートへ接続） |
| パッシブ | **クライアント → サーバ**（サーバが指定したポートへ接続） |

NAT や Docker のポート転送の内側ではアクティブモードが機能しません。よってパッシブモードを使い、そのポート範囲（`21000-21010`）を明示的に公開します。`pasv_address` は「クライアントが接続し直すべきアドレス」で、Docker 越しではコンテナ IP ではなく**ホストのアドレス**を返す必要があります。

### 14.2 chroot と権限

| 設定 | 意味 |
|---|---|
| `chroot_local_user=YES` | ログイン後はホームより上に出られない |
| `allow_writeable_chroot=YES` | chroot 先が書き込み可能でも起動を許可（本来 vsftpd は安全性のため拒否する） |
| `local_root=/var/www/html` | ログイン直後の位置 |
| `userlist_enable=YES` + `userlist_deny=NO` | 許可リスト方式（`ftpuser` の1名のみ） |
| シェルは `/usr/sbin/nologin` | FTP はできるが SSH などでシェルは取れない |

FTP ユーザーは `www-data` グループに追加し、`/var/www/html` にグループ書き込み権を与えることで WordPress ファイルを更新できます。

### 14.3 注意点（実運用の観点）

FTP は**認証情報もデータも平文**で流れます。課題のボーナスとしては要求どおりですが、実運用では SFTP / FTPS を選ぶべきです。評価でこの点に触れられると加点になります。

---

## 15. cron とバックアップ

### 15.1 cron が環境変数を継承しない

cron はデーモンとして起動し、ジョブを**最小限の環境**で実行します。コンテナの環境変数（`MYSQL_HOST` など）はジョブに引き継がれません。そこで entrypoint がジョブファイル自体に変数を書き出します。

```
/etc/cron.d/inception-backup
────────────────────────────
MYSQL_HOST=mariadb
MYSQL_PORT=3306
MYSQL_DATABASE=wordpress
MYSQL_USER=wp_user
BACKUP_RETENTION_DAYS=7
0 3 * * * root /usr/local/bin/backup.sh >> /proc/1/fd/1 2>&1
```

- `/etc/cron.d/` のファイルは**ユーザー名フィールドが必要**（`root`）。crontab 形式との違いに注意。
- パーミッションは `0644` でなければ無視されます。
- 出力を `/proc/1/fd/1` に流すことで `docker logs backup` から読めます。

### 15.2 cron 式

```
分 時 日 月 曜日  ユーザー  コマンド
0  3  *  *  *     root      /usr/local/bin/backup.sh
```

上記は「毎日 3:00」。

### 15.3 「自由選択のサービス」として何を主張するか

評価では選定理由の説明を求められます。要点:

> ボリュームはコンテナの障害からデータを守るが、**論理的な破壊（誤った DELETE、テーブル破損、プラグインの暴走）からは守らない**。世代管理された論理バックアップを別ボリュームに持つことで、「どの時点にでも戻せる」という別種の保証を追加している。専用の Dockerfile・専用のボリューム・フォアグラウンドの cron という課題の作法にも合致する。

---

## 16. 評価（defense）想定質問集

### Docker 全般

**Q. VM とコンテナの違いを説明してください。**
A. VM はハイパーバイザ上で別のカーネルを起動する仮想的なコンピュータで、分離は強いが起動が遅く容量も大きい。コンテナはホストカーネル上のプロセスを namespace と cgroup で隔離したもので、起動が速く軽い代わりにカーネルを共有する。このプロジェクトでは VM が「学校のマシンからの隔離」、Docker が「サービス同士の隔離」を担当している。

**Q. なぜ Alpine ではなく Debian を選びましたか。**
A. どちらでもよいが、WordPress / php-fpm / MariaDB のパッケージが枯れていて設定パスも標準的な Debian を選んだ。Alpine は musl libc と BusyBox のためイメージは小さいが、PHP 拡張や `mariadb-install-db` の挙動差でハマりやすい。今回は「確実に要件を満たすこと」を優先した。

**Q. なぜ `latest` タグが禁止なのですか。**
A. `latest` は「最新」という意味ではなく、単に既定のタグ名。指す中身が時間とともに変わるので、同じ Dockerfile でも別のイメージができ上がり再現性が失われる。このプロジェクトはベースを `debian:bookworm`、自作イメージを `<service>:inception`、ダウンロードするものも全てバージョン固定にしている。

**Q. イメージとコンテナの違いは。**
A. イメージは読み取り専用のレイヤーの積み重ね（テンプレート）。コンテナはそのイメージに書き込み可能レイヤーを1枚重ねて実行したインスタンス。同じイメージから複数のコンテナを作れる。

### PID 1・プロセス

**Q. なぜ `tail -f` や `sleep infinity` が禁止なのですか。**
A. それらを PID 1 にすると、(1) `docker stop` の SIGTERM が本体プロセスに届かず強制終了になる、(2) 本体が死んでも PID 1 が生きているのでコンテナは "Up" のままになり、`restart: always` も発動しない。つまりコンテナの安全停止と死活監視を壊すから。

**Q. `exec` は何のために書いていますか。**
A. シェルスクリプトを本体プロセスに**置き換える**ため。`exec` がないと、entrypoint のシェルが PID 1 のまま残り、本体はその子プロセスになるので上と同じ問題が起きる。

**Q. PID 1 は何が特別なのですか。**
A. 孤児プロセスを引き取ってゾンビを回収する義務があること、そして**シグナルの既定動作が無効**であること。ハンドラを登録していないプロセスを PID 1 にすると SIGTERM を無視してしまう。

**Q. DB の起動を待つループは禁止事項に当たりませんか。**
A. 当たらない。禁止されているのは「コンテナを生かし続けるための無限ループ」。こちらは最大30回・約60秒で打ち切り、失敗すれば明示的に異常終了する有限ループ。しかも本来は compose の `depends_on: condition: service_healthy` が待機を担当しており、このループは保険。

### ネットワーク

**Q. コンテナ同士はどうやって通信していますか。**
A. `inception` というユーザー定義 bridge ネットワークを1つ作り、全コンテナを接続している。Docker 内蔵 DNS（127.0.0.11）がサービス名を解決するので、nginx は `wordpress:9000`、WordPress は `mariadb:3306` という名前で接続できる。IP のハードコードは不要。

**Q. なぜ `network: host` が禁止なのですか。**
A. ネットワークの分離が消え、コンテナのポートがそのままホストのポートになるため「nginx が唯一の入口」を保証できなくなる。加えてサービス名の名前解決ができず、同じポートを使うコンテナを複数動かせない。

**Q. `expose` と `ports` の違いは。**
A. `expose` は宣言だけでホストには公開されない（同一ネットワークのコンテナからは元々到達できる）。`ports` はホストのポートを転送して外部から到達可能にする。このプロジェクトでは nginx の 443 だけが `ports`（FTP はボーナス規定で追加）。

**Q. Adminer と静的サイトはポートを開けていないのに、どうやって見えるのですか。**
A. nginx が `/adminer/` と `/static/` をリバースプロキシしている。これにより「443 が唯一の入口」という必須要件を崩さずにボーナスを追加できる。

### ボリューム

**Q. 名前付きボリュームとバインドマウントの違いは。**
A. 名前付きボリュームは Docker が管理するオブジェクトで、名前で参照でき、`docker volume inspect` で情報が取れ、`compose down` でも消えない。バインドマウントはホストの任意パスを直結するだけで Docker の管理対象外、ホストの構成と UID/GID に依存する。

**Q. `driver_opts` で bind を指定しているなら、それはバインドマウントでは？**
A. マウントの**実装**は bind だが、Docker から見た**オブジェクト**は名前付きボリューム。サービス定義は `wordpress:/var/www/html` と名前で参照しており、`docker volume ls` にも出る。課題は「名前付きボリュームを使うこと」と「データを `/home/login/data` に置くこと」を同時に要求しているので、この形が両立する唯一の素直な解。サービス定義にバインドマウント記法は1つも書いていない。

**Q. データが消えないことはどう保証していますか。**
A. 2段構え。(1) データは名前付きボリュームにあり `down` では消えない。(2) entrypoint が冪等で、`/var/lib/mysql/mysql` や `wp-config.php` の存在を見て初期化をスキップする。実際に `make down && make` して投稿が残ることを確認済み。

**Q. ボリュームの copy-up でハマったと聞きましたが。**
A. `mariadb-server` パッケージがイメージ内 `/var/lib/mysql` にシステムテーブルを作るため、空のボリュームにその中身がコピーされ、entrypoint が「初期化済み」と誤判定して DB もユーザーも作られなかった。Dockerfile の最後で `rm -rf /var/lib/mysql/*` して空のデータディレクトリを出荷することで解決した。nginx の `/var/www/html` でも同じ対処をしている。

### シークレット・環境変数

**Q. パスワードはどこにありますか。**
A. `secrets/*.txt` にだけ。compose の `secrets:` でコンテナの `/run/secrets/` にファイルとしてマウントし、entrypoint が実行時に読む。Dockerfile にも `.env` にも書いていない。`secrets/*.txt` と `srcs/.env` は `.gitignore` で除外し、リポジトリには機密を含まない `.env.example` だけを置いている。

**Q. 環境変数ではなく secrets を使う理由は。**
A. 環境変数は `docker inspect` や `/proc/<pid>/environ` から読め、子プロセスに自動継承され、ログにも漏れやすい。secrets はファイルとして宣言したコンテナにだけ渡り、イメージにも `docker inspect` にも現れない。設定値は `.env`、パスワードは secrets、と役割で分けている。

**Q. `.env` に秘密情報が無いなら git に入れてもよいのでは。**
A. 技術的には可能だが、「`.env` は追跡しない」というルールを徹底しておけば後日パスワードを書き足しても事故にならない。必要な変数一覧は `.env.example` で共有している。

### nginx / TLS

**Q. TLS 1.2 と 1.3 だけにしている設定はどこですか。**
A. `srcs/requirements/nginx/conf/default.conf` の `ssl_protocols TLSv1.2 TLSv1.3;`。列挙外のバージョンはハンドシェイクの段階で拒否される。`openssl s_client -tls1_1` で `no protocols available` になることを確認済み。

**Q. 証明書はどこから来ていますか。**
A. nginx の entrypoint が起動時に `openssl req -x509` で自己署名証明書を生成している。CN と SAN に `${DOMAIN_NAME}` を入れており、鍵は `chmod 600`。自己署名なのでブラウザは警告を出すが、暗号化そのものは正しく機能している。

**Q. なぜ 80 番を開いてリダイレクトしないのですか。**
A. 課題が「443 のみが入口」と明記しているため。80 を開くと最初のリクエストは平文で流れることになり、要件を厳密には満たさない。

**Q. nginx はどうやって PHP を実行していますか。**
A. 実行していない。`.php` へのリクエストは FastCGI プロトコルで `wordpress:9000` の php-fpm に渡し、結果を受け取って返しているだけ。だから nginx コンテナには PHP が入っていない。

**Q. `fastcgi_param HTTPS on` は何のためですか。**
A. TLS を終端しているのは nginx なので、php-fpm には平文のリクエストとして届く。これを渡さないと WordPress が「HTTPS なのに HTTP で来た」と判断してリダイレクトループを起こすことがある。

### WordPress / DB

**Q. WordPress のユーザーは誰と誰ですか。**
A. 管理者が `chief_dreamer`、もう1人が `cobb`（author 権限）。管理者名に `admin` / `administrator` を含めない要件があり、entrypoint 側でも文字列検査して違反時は起動を止めている。

**Q. WordPress はどうやってインストールされましたか。**
A. wp-cli で自動化している。`wp core download` → `wp config create` → `wp core install` → `wp user create` の順。2回目以降は `wp-config.php` の有無で判定してスキップする。

**Q. MariaDB の初期化で一時サーバを立てていないのはなぜですか。**
A. `mariadbd --bootstrap` を使っているから。標準入力から SQL を読んで実行し、終わったら終了する単発モードなので、「一時起動 → sleep で待つ → SQL → 停止」というループとスリープの塊を避けられる。

**Q. root ユーザーの権限は。**
A. `root@'localhost'` のみで、ネットワーク越しにはログインできない。アプリケーションが使うのは `wp_user@'%'` で、権限は `wordpress` データベースに限定している。匿名ユーザーと `test` データベースも初期化時に削除している。

### Compose / 運用

**Q. サービスの起動順序はどう制御していますか。**
A. `depends_on` に `condition: service_healthy` を付け、MariaDB のヘルスチェック（`mariadb-admin ping`）が通ってから WordPress を起動している。単なる `depends_on` は「コンテナが起動した」ことしか保証しないため、条件付きにするのが重要。

**Q. コンテナが落ちたらどうなりますか。**
A. 全サービスに `restart: always` を付けているので Docker が自動再起動する。entrypoint は冪等なので、再起動してもデータを壊さず途中から復帰する。

**Q. ボーナス無しで動かせますか。**
A. `make mandatory` で必須3サービスだけ起動できる。ボーナスは compose のプロファイル `bonus` に入れており、同時に `.env` の `ENABLE_BONUS=0` を設定して nginx が `/adminer/` `/static/` のルートを出力しないようにしている。

**Q. ログはどう見ますか。**
A. `make logs` で全体、`docker logs <service>` で個別。全サービスがログを標準出力/標準エラーに出すよう設定してある（MariaDB は `log_error` を未設定にし、php-fpm は `catch_workers_output`、Redis は `logfile ""`、vsftpd は `/proc/1/fd/1` へのシンボリックリンク）。

---

## 17. トラブルシューティング

| 症状 | 主な原因 | 確認・対処 |
|---|---|---|
| `docker compose up` がボリューム作成で失敗 | `${DATA_PATH}` のディレクトリが無い | `make setup`（`dirs` が作成する） |
| mariadb が再起動を繰り返す | データディレクトリの権限、または設定ファイルの誤り | `docker logs mariadb`。`/home/kkuramot/data/mariadb` の所有者を確認 |
| WordPress が DB に繋がらない | ユーザーが作られていない（初期化スキップの誤判定） | `docker exec -it mariadb mariadb -h localhost --protocol=socket -u root -p… -e "SELECT user,host FROM mysql.user"`。`make fclean && make` で作り直す |
| nginx が `unknown directive` で起動しない | nginx のバージョン差 | `docker logs nginx`。bookworm は 1.22 なので `http2 on;` は使えない |
| ブラウザで証明書の警告が出る | 自己署名証明書 | 正常。例外を承認して進む |
| `ERR_CONNECTION_REFUSED`（http://） | 80 番を開いていない | `https://` でアクセスする |
| ドメインで開けない | `/etc/hosts` 未設定 | `make hosts` |
| wp-admin でリダイレクトループ | HTTPS 判定の失敗 | `fastcgi_param HTTPS on;` と `wp-config.php` の `X-Forwarded-Proto` 判定を確認 |
| redis が再起動ループ | `redis.conf` の行末コメント | コメントを独立行にする |
| FTP が `530 Login incorrect` | PAM の `/etc/shells` 検査 | `/usr/sbin/nologin` を `/etc/shells` に追加 |
| FTP でファイル一覧が出ない | パッシブポート範囲・`pasv_address` の不一致 | 公開ポート範囲と conf を一致させる。`FTP_PASV_ADDRESS` を確認 |
| Adminer で接続できない | Server 欄に `localhost` を入れている | `mariadb` を指定する |
| `docker exec mariadb mariadb …` が拒否される | `MYSQL_HOST` 環境変数により TCP 接続になっている | `-h localhost --protocol=socket` を付ける |
| 変更が反映されない | 設定は COPY されているためイメージの再ビルドが必要 | `up -d --build <service>` |

---

## 18. 用語集

| 用語 | 意味 |
|---|---|
| **namespace** | プロセスから「見えるもの」を分離する Linux の機能（pid, net, mnt, uts, ipc, user） |
| **cgroup** | プロセスが「使える量」を制限する Linux の機能（CPU, メモリ, I/O） |
| **レイヤー** | イメージを構成する読み取り専用の差分。Dockerfile の各命令が1つ作る |
| **copy-on-write** | 書き込み時に初めて上位レイヤーへコピーする方式 |
| **copy-up** | 空の名前付きボリュームにイメージ側の内容がコピーされる Docker の挙動 |
| **PID 1** | コンテナの最初のプロセス。孤児回収の責任を持ち、シグナルの既定動作が無効 |
| **graceful shutdown** | 処理中の要求を捌き切ってから終了すること |
| **exec 形式** | `CMD ["a","b"]` の記法。シェルを介さず直接実行される |
| **FastCGI** | Web サーバと常駐アプリ間のバイナリプロトコル |
| **php-fpm** | PHP の FastCGI プロセスマネージャ |
| **リバースプロキシ** | クライアントの要求を受けて背後のサーバへ中継するサーバ |
| **TLS 終端** | プロキシが暗号を解き、背後には平文で流す構成 |
| **SAN** | 証明書の Subject Alternative Name。現代のブラウザはここでホスト名を検証する |
| **前方秘匿性 (PFS)** | 秘密鍵が漏れても過去の通信は復号できない性質。ECDHE により実現 |
| **AEAD** | 暗号化と認証を同時に行う方式（AES-GCM, ChaCha20-Poly1305） |
| **論理バックアップ** | SQL 文の形で出力するバックアップ（`mariadb-dump`） |
| **物理バックアップ** | データファイルをそのままコピーするバックアップ |
| **オブジェクトキャッシュ** | DB クエリ結果などをキーバリューで保持する仕組み |
| **LRU** | Least Recently Used。最も長く使われていないものから捨てる方式 |
| **ドロップイン** | WordPress が既定実装を差し替えるために読み込む特別なファイル（`object-cache.php` など） |
| **パッシブモード** | FTP でデータ接続をクライアント側から張る方式 |
| **chroot** | プロセスから見えるルートディレクトリを制限すること |
| **冪等** | 何度実行しても結果が同じであること |
| **プロファイル (Compose)** | 特定の指定時だけサービスを有効化する仕組み |

---

## 19. 参考資料

### 公式ドキュメント

- [Docker Docs](https://docs.docker.com/) — Dockerfile / Compose / volumes / secrets / networks
- [Dockerfile best practices](https://docs.docker.com/build/building/best-practices/)
- [Compose file reference](https://docs.docker.com/reference/compose-file/)
- [nginx documentation](https://nginx.org/en/docs/) — `ssl_protocols`, `fastcgi_pass`, `proxy_pass`, `resolver`
- [MariaDB Knowledge Base](https://mariadb.com/kb/en/) — `mariadb-install-db`, `--bootstrap`, 権限管理
- [PHP: FPM Configuration](https://www.php.net/manual/en/install.fpm.configuration.php)
- [WP-CLI Handbook](https://make.wordpress.org/cli/handbook/)
- [WordPress: Editing wp-config.php](https://wordpress.org/documentation/article/editing-wp-config-php/)
- [Redis configuration](https://redis.io/docs/latest/operate/oss_and_stack/management/config/)
- [vsftpd.conf(5)](https://security.appspot.com/vsftpd/vsftpd_conf.html)

### 設定生成・検証

- [Mozilla SSL Configuration Generator](https://ssl-config.mozilla.org/) — 暗号スイートの根拠
- [SSL Labs](https://www.ssllabs.com/ssltest/) — 公開サーバの TLS 検証（ローカルでは `openssl s_client`）

### 規格

- RFC 8446 — TLS 1.3
- RFC 5246 — TLS 1.2
- RFC 8996 — TLS 1.0 / 1.1 の廃止
