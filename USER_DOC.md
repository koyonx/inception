# User documentation

This document is for someone who wants to **run and use** the stack, not to
modify it. For the build and the internals, see [`DEV_DOC.md`](DEV_DOC.md).

---

## 1. What the stack provides

Once started, the project runs a complete WordPress website behind HTTPS.

### Mandatory services

| Container   | What it does                                          | How you reach it |
|-------------|-------------------------------------------------------|------------------|
| `nginx`     | The only entrypoint. Terminates TLS (TLSv1.2/1.3) on port 443 and forwards PHP to WordPress. | `https://kkuramot.42.fr` |
| `wordpress` | WordPress + php-fpm. Generates the pages.             | through nginx only |
| `mariadb`   | The database holding all the site content.            | through the other containers only |

### Bonus services (started by `make`, skipped by `make mandatory`)

| Container     | What it does                                            | How you reach it |
|---------------|---------------------------------------------------------|------------------|
| `redis`       | Object cache: WordPress stores query results in memory. | internal |
| `ftp`         | Upload/download the website files with any FTP client.  | `ftp://<host-ip>:21` |
| `adminer`     | Web interface to browse and edit the database.          | `https://kkuramot.42.fr/adminer/` |
| `static-site` | A small static showcase page (HTML/CSS, no PHP).        | `https://kkuramot.42.fr/static/` |
| `backup`      | Takes a compressed dump of the database every night.    | dumps in the `backup` volume |

---

## 2. Starting and stopping

All the commands are run from the root of the repository, where the `Makefile`
is.

### First start

```sh
make hosts    # once: adds "127.0.0.1 kkuramot.42.fr" to /etc/hosts
make          # creates the data folders + secrets, builds, starts
```

The first run takes a few minutes: the images are built, then WordPress
downloads and installs itself. Follow it with `make logs`.

### Everyday commands

| Goal                                   | Command        |
|----------------------------------------|----------------|
| Start everything                       | `make`         |
| Start only the three mandatory services| `make mandatory` |
| Stop and remove the containers (data kept) | `make down` |
| Pause without removing                 | `make stop`    |
| Resume                                 | `make start`   |
| Restart from scratch, keeping the data | `make restart` |
| See the status                         | `make ps`      |
| Follow the logs                        | `make logs`    |

### Removing things

| Goal                                                     | Command       |
|----------------------------------------------------------|---------------|
| Remove the containers **and the images** (data kept)      | `make clean`  |
| Remove **everything**, including the site and the database| `make fclean` |

> `make fclean` deletes `/home/kkuramot/data`. The website content and the
> database are gone for good. `make down` is what you want for a normal stop.

---

## 3. Accessing the website and the admin panel

| Page                | URL                                        |
|---------------------|--------------------------------------------|
| Website             | `https://kkuramot.42.fr`                    |
| Administration      | `https://kkuramot.42.fr/wp-admin/`          |
| Database manager    | `https://kkuramot.42.fr/adminer/` *(bonus)* |
| Static showcase site| `https://kkuramot.42.fr/static/` *(bonus)*  |

The certificate is **self-signed**, so the browser shows a warning the first
time ("Your connection is not private"). This is expected: accept the
exception and continue. Only `https://` works — port 80 is not open at all.

Two WordPress accounts are created automatically:

* the **administrator** — user name taken from `WP_ADMIN_USER` in `srcs/.env`
  (`chief_dreamer` by default; it must never contain "admin");
* a **regular user** — `WP_USER` (`cobb` by default), created with the
  `author` role.

For Adminer, log in with:

| Field    | Value                                       |
|----------|---------------------------------------------|
| System   | MySQL / MariaDB                             |
| Server   | `mariadb`                                   |
| Username | the value of `MYSQL_USER` in `srcs/.env`    |
| Password | the content of `secrets/db_password.txt`    |
| Database | the value of `MYSQL_DATABASE`               |

For FTP, connect to the host IP on port 21 with the user `FTP_USER`
(`ftpuser`) and the password in `secrets/ftp_password.txt`. Use **passive
mode**; the session lands directly in the WordPress files.

---

## 4. Where the credentials live

Nothing is hard-coded and nothing is committed. `make setup` generates random
passwords the first time and stores them in `secrets/`, which git ignores:

| File                            | Contains                                     |
|---------------------------------|----------------------------------------------|
| `secrets/db_root_password.txt`  | MariaDB `root` password                      |
| `secrets/db_password.txt`       | password of the WordPress database user      |
| `secrets/ftp_password.txt`      | password of the FTP user                     |
| `secrets/credentials.txt`       | `WP_ADMIN_PASSWORD=…` and `WP_USER_PASSWORD=…` |

Read them with:

```sh
cat secrets/credentials.txt
cat secrets/db_password.txt; echo
```

Non-sensitive settings (domain name, user names, database name) are in
`srcs/.env`, generated from `srcs/.env.example`.

### Changing a password

* **WordPress users** — change it from the admin panel, or:
  ```sh
  docker exec -it wordpress wp --allow-root --path=/var/www/html \
      user update <user> --user_pass='new-password'
  ```
  then update `secrets/credentials.txt` so it stays in sync.
* **Database / FTP** — the passwords are only read when the data directory or
  the user is created. Edit the file in `secrets/`, then recreate the affected
  service (`make fclean && make` for the database — this erases the data).

---

## 5. Checking that everything works

```sh
make ps
```

`nginx`, `wordpress` and `mariadb` must be `Up`, the first two also `(healthy)`.

```sh
# the site answers over TLS
curl -kI https://kkuramot.42.fr

# TLSv1.2 and TLSv1.3 are accepted...
openssl s_client -connect kkuramot.42.fr:443 -tls1_2 </dev/null
openssl s_client -connect kkuramot.42.fr:443 -tls1_3 </dev/null

# ...and everything older is refused
openssl s_client -connect kkuramot.42.fr:443 -tls1_1 </dev/null   # must fail

# port 80 is closed
curl -I http://kkuramot.42.fr                                     # must fail

# the two WordPress users exist
docker exec -it wordpress wp --allow-root --path=/var/www/html user list

# the data really is on the host
ls -l /home/kkuramot/data/wordpress /home/kkuramot/data/mariadb
```

Persistence check — the site must survive a full restart:

```sh
make down && make
```

The posts, the users and the media are still there because they live in the
named volumes, not in the containers.

If a container keeps restarting, read its logs:

```sh
docker logs mariadb
docker logs wordpress
docker logs nginx
```
