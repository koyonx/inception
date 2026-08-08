*This project has been created as part of the 42 curriculum by kkuramot.*

# Inception

## Description

Inception is a system administration project: build a small, complete web
infrastructure from scratch with Docker, and run it inside a virtual machine.

Nothing is pulled ready-made. Every image of this repository is built from a
`Dockerfile` written here, on top of the penultimate stable Debian release
(`debian:bookworm`), and every service runs in its own dedicated container:

| Service     | Role                                             | Exposed |
|-------------|--------------------------------------------------|---------|
| `nginx`     | TLS reverse proxy, the **only** entrypoint       | `443` (host) |
| `wordpress` | WordPress + php-fpm, **no** web server inside    | `9000` (internal) |
| `mariadb`   | Database, **no** web server inside               | `3306` (internal) |

Two Docker **named volumes** hold the state — one for the database, one for the
website files — and both store their data under `/home/kkuramot/data` on the
host. A dedicated bridge network (`inception`) connects the containers; neither
`network: host` nor `links:` is used anywhere.

A bonus layer adds five more containers: `redis` (object cache), `ftp`
(vsftpd on the website volume), `adminer` (database client), `static-site`
(a plain HTML/CSS showcase page) and `backup` (scheduled database dumps).

```
                        ┌──────────────── HOST ───────────────────────┐
 https://kkuramot.42.fr │                                             │
       :443 ───────────►│  ┌── docker network "inception" ─────────┐  │
                        │  │                                       │  │
                        │  │  nginx ──9000──► wordpress ──3306──►  │  │
                        │  │    │             (php-fpm)   mariadb  │  │
                        │  │    │                 │           │    │  │
                        │  └────┼─────────────────┼───────────┼────┘  │
                        │       ▼                 ▼           ▼       │
                        │   volume "wordpress"        volume "mariadb" │
                        │   /home/kkuramot/data/{wordpress,mariadb}    │
                        └─────────────────────────────────────────────┘
```

## Instructions

Everything goes through the `Makefile` at the root of the repository.

```sh
# 1. point the domain name at the machine (once, needs sudo)
make hosts

# 2. build the images, create the volumes and start everything
make

# 3. open the site
#    https://kkuramot.42.fr        WordPress
#    https://kkuramot.42.fr/wp-admin/
```

`make setup` alone creates `/home/kkuramot/data`, generates `srcs/.env` from
`srcs/.env.example` and fills `secrets/` with freshly generated random
passwords. The credentials are printed nowhere: read them with
`cat secrets/credentials.txt`.

| Command         | Effect                                                    |
|-----------------|-----------------------------------------------------------|
| `make`          | build + start everything (mandatory **and** bonus)        |
| `make mandatory`| build + start only nginx / wordpress / mariadb            |
| `make down`     | stop and remove the containers, keep the data             |
| `make clean`    | the above + remove the images                             |
| `make fclean`   | the above + remove the volumes and `/home/kkuramot/data`   |
| `make re`       | `fclean` then a full rebuild                              |
| `make logs`     | follow the logs of every container                        |
| `make ps`       | status of the containers                                  |

The login is set once in the `Makefile` (`LOGIN ?= kkuramot`) and drives both
the domain name and the data path; it can still be overridden on the command
line with `make LOGIN=wil`.

More detail: [`USER_DOC.md`](USER_DOC.md) for day-to-day usage,
[`DEV_DOC.md`](DEV_DOC.md) for the build and the internals.

Japanese notes (日本語): [`docs/SPEC.ja.md`](docs/SPEC.ja.md) is a detailed
specification of every service, and [`docs/KNOWLEDGE.ja.md`](docs/KNOWLEDGE.ja.md)
collects the background knowledge behind the design choices.

## Project description

### Use of Docker and sources included

The repository contains no binary and no third-party image. Each service
directory under `srcs/requirements/` holds its own `Dockerfile`, its
configuration files (`conf/`) and its entrypoint script (`tools/`).
`srcs/docker-compose.yml` wires them together and is only ever invoked through
the `Makefile`.

The sources fetched at build time are limited to what cannot be committed:
the Debian packages (`apt`), the WordPress tarball and wp-cli, the
`redis-cache` plugin, and the single Adminer PHP file. Their versions are
pinned — the `latest` tag is used nowhere.

### Main design choices

* **One process per container, and that process is PID 1.** Every entrypoint
  ends with `exec`, so nginx, `mariadbd`, `php-fpm -F`, `redis-server`,
  `vsftpd` and `cron -f` each receive the signals directly and shut down
  cleanly. There is no `tail -f`, no `sleep infinity`, no `while true`
  anywhere in this repository. The only loop is a *bounded* retry (30 attempts)
  that waits for MariaDB before installing WordPress.
* **Idempotent entrypoints.** MariaDB initialises its data directory only when
  `/var/lib/mysql/mysql` is missing; WordPress installs itself only when
  `wp-config.php` is missing. Restarting a container never destroys data, and
  `restart: always` makes a crashed container come back on its own.
* **No password in a Dockerfile, and none in the repository.** Passwords live
  in `secrets/*.txt`, mounted by Docker as files under `/run/secrets/`, and are
  read by the entrypoints at run time. `secrets/*.txt` and `srcs/.env` are
  git-ignored; `srcs/.env.example` is the committed template and contains no
  credential.
* **TLS only.** nginx listens on 443 with `ssl_protocols TLSv1.2 TLSv1.3;`
  and nothing else. Port 80 is never opened. The certificate is self-signed
  for `kkuramot.42.fr` and generated on first start.
* **Bonus behind the same door.** Adminer and the static site are proxied at
  `/adminer/` and `/static/`, so the mandatory rule "nginx is the only
  entrypoint" still holds. Only FTP needs its own published ports, which the
  subject allows for the bonus part.

### Virtual Machines vs Docker

A virtual machine emulates a whole computer: it boots its own kernel on top of
a hypervisor, with its own virtual disk and virtual devices. The isolation is
almost total, but the cost is high — gigabytes of disk, a full boot sequence,
and a fixed slice of RAM per VM.

A container is just a group of processes on the **host kernel**, fenced off
with namespaces (pid, net, mount, user…) and limited with cgroups. There is no
guest kernel and no boot: starting a container is starting a process. That is
why this whole infrastructure — six to nine services — fits comfortably inside
a single small VM, whereas one VM per service would not.

The trade-off is the shared kernel: a container cannot run a different OS
kernel, and a kernel-level escape affects the host. This project uses both
layers on purpose: the VM isolates the project from the school machine, Docker
isolates the services from each other.

### Secrets vs Environment Variables

Environment variables are convenient and are the right tool for
*configuration*: the domain name, the database name, the user names, the redis
host. They are visible in `docker inspect`, in `/proc/<pid>/environ`, and they
are inherited by every child process — which makes them a poor place for a
password.

Docker secrets are mounted as read-only files under `/run/secrets/`, are not
part of the image, are not shown by `docker inspect`, and are only readable
inside the container that declares them. In this project:

* `srcs/.env` → non-sensitive configuration (`DOMAIN_NAME`, `MYSQL_DATABASE`,
  `MYSQL_USER`, `WP_ADMIN_USER`, …);
* `secrets/*.txt` → every password (`db_root_password`, `db_password`,
  `credentials`, `ftp_password`), read by the entrypoints with `cat`.

Both are git-ignored, and the passwords never appear in a `Dockerfile`, in a
`docker history`, or in a build argument.

### Docker Network vs Host Network

With `network_mode: host`, a container shares the host network stack: every
port it opens is a port on the host, service names do not resolve, and two
containers cannot both listen on 3306. It also removes the network isolation
that makes the "single entrypoint" rule enforceable — and the subject forbids
it.

This project declares a user-defined bridge network, `inception`. Docker runs
an embedded DNS server at `127.0.0.11`, so `wordpress` reaches the database by
the name `mariadb` and nginx reaches php-fpm at `wordpress:9000`. Only the
ports listed under `ports:` are published — `443` for nginx (plus the FTP
ports in the bonus). MariaDB and php-fpm use `expose:` only: they are
reachable from the network's containers and from nowhere else.

### Docker Volumes vs Bind Mounts

A bind mount maps an arbitrary host path into a container. It depends on the
host layout and on the host's uid/gid, it can silently shadow image content,
and it is not a Docker object — `docker volume ls` does not know about it.

A named volume is managed by Docker: it has a name, a lifecycle, a driver, and
it survives `docker compose down`. This project uses named volumes
(`mariadb`, `wordpress`, `redis`, `backup`) as the subject requires. Their data
still has to land in `/home/kkuramot/data`, so each volume is declared with the
`local` driver and `driver_opts` (`type: none`, `o: bind`,
`device: ${DATA_PATH}/…`): the object stays a *named volume* — services mount
it by name, `docker volume inspect wordpress` describes it — while its backing
storage is the required host folder. No service definition contains a bind
mount.

## Resources

* [Docker documentation](https://docs.docker.com/) — Dockerfile reference,
  Compose file reference, named volumes, secrets, user-defined networks
* [Docker: Run multiple processes in a container / PID 1](https://docs.docker.com/engine/containers/multi-service_container/)
* [Best practices for writing Dockerfiles](https://docs.docker.com/build/building/best-practices/)
* [MariaDB Knowledge Base — `mariadb-install-db`, `--bootstrap`](https://mariadb.com/kb/en/mariadb-install-db/)
* [WordPress Codex — `wp-config.php`](https://wordpress.org/documentation/article/editing-wp-config-php/)
  and [WP-CLI handbook](https://make.wordpress.org/cli/handbook/)
* [nginx docs — `ssl_protocols`, `fastcgi_pass`, `proxy_pass`](https://nginx.org/en/docs/)
* [Mozilla SSL Configuration Generator](https://ssl-config.mozilla.org/) — the
  cipher suite used in `default.conf`
* [php-fpm pool configuration](https://www.php.net/manual/en/install.fpm.configuration.php)
* [vsftpd.conf(5)](https://security.appspot.com/vsftpd/vsftpd_conf.html)
* [Redis configuration reference](https://redis.io/docs/latest/operate/oss_and_stack/management/config/)

### Use of AI

An AI assistant (Claude, via Claude Code) was used on this project for:

* **reading and summarising the subject** into a checklist of constraints
  (TLS versions, forbidden patterns, volume rules, README requirements);
* **scaffolding the repository**: the directory layout, the `Makefile`
  targets, and the first draft of the `Dockerfile`s, the entrypoint scripts,
  the nginx/php-fpm/MariaDB configuration files and `docker-compose.yml`;
* **drafting the documentation**: this `README.md`, `USER_DOC.md` and
  `DEV_DOC.md`.

Every generated file was then read, tested and adjusted by hand — in
particular the entrypoints (PID 1 behaviour, idempotency, secret handling),
the TLS configuration and the volume declarations. The AI was **not** used to
answer the defence questions: the design choices above are explained in my own
words.
