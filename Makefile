# **************************************************************************** #
#                                  INCEPTION                                   #
# **************************************************************************** #

# 42 login: decides the domain name and the host data path.
# Override on the command line if needed:  make LOGIN=wil
LOGIN       ?= kkuramot

DOMAIN_NAME := $(LOGIN).42.fr
DATA_PATH   := /home/$(LOGIN)/data

NAME        := inception
SRCS        := srcs
COMPOSE     := docker compose -p $(NAME) -f $(SRCS)/docker-compose.yml --env-file $(SRCS)/.env
ENV_FILE    := $(SRCS)/.env
ENV_SAMPLE  := $(SRCS)/.env.example
SECRETS     := secrets

VOLUMES     := mariadb wordpress redis backup

GREEN  := \033[0;32m
YELLOW := \033[0;33m
BLUE   := \033[0;34m
RESET  := \033[0m

.DEFAULT_GOAL := all
.PHONY: all mandatory setup env secrets dirs hosts build up down stop start \
        restart re logs ps status clean fclean prune help

# ---------------------------------------------------------------- main targets

## Build and start the whole stack (mandatory + bonus)
all: setup
	@printf "$(BLUE)==> Building and starting Inception (with bonus)$(RESET)\n"
	@$(COMPOSE) --profile bonus up --build -d
	@$(MAKE) --no-print-directory ps

## Build and start only the mandatory services (nginx, wordpress, mariadb)
mandatory: setup
	@printf "$(BLUE)==> Building and starting Inception (mandatory only)$(RESET)\n"
	@sed -i.bak 's/^ENABLE_BONUS=.*/ENABLE_BONUS=0/' $(ENV_FILE) && rm -f $(ENV_FILE).bak
	@$(COMPOSE) up --build -d
	@$(MAKE) --no-print-directory ps

## Build the images without starting the containers
build: setup
	@$(COMPOSE) --profile bonus build

## Start the containers (images must already exist)
up: setup
	@$(COMPOSE) --profile bonus up -d

## Stop and remove the containers (volumes and data are kept)
down:
	@printf "$(YELLOW)==> Stopping containers$(RESET)\n"
	@$(COMPOSE) --profile bonus down

stop:
	@$(COMPOSE) --profile bonus stop

start:
	@$(COMPOSE) --profile bonus start

restart: down all

re: fclean all

# ------------------------------------------------------------------- bootstrap

## Create the host data folders, the .env file and the secrets
setup: dirs env secrets

dirs:
	@printf "$(BLUE)==> Creating host data folders in $(DATA_PATH)$(RESET)\n"
	@for v in $(VOLUMES); do \
		if [ ! -d "$(DATA_PATH)/$$v" ]; then \
			mkdir -p "$(DATA_PATH)/$$v" 2>/dev/null \
			|| sudo mkdir -p "$(DATA_PATH)/$$v"; \
		fi; \
	done
	@sudo chown -R $(USER):$(USER) $(DATA_PATH) 2>/dev/null || true

env:
	@if [ ! -f $(ENV_FILE) ]; then \
		printf "$(BLUE)==> Generating $(ENV_FILE) for login '$(LOGIN)'$(RESET)\n"; \
		sed 's/__LOGIN__/$(LOGIN)/g' $(ENV_SAMPLE) > $(ENV_FILE); \
	else \
		printf "$(GREEN)==> $(ENV_FILE) already exists, keeping it$(RESET)\n"; \
	fi

secrets:
	@mkdir -p $(SECRETS)
	@if [ ! -f $(SECRETS)/db_root_password.txt ]; then \
		printf "$(BLUE)==> Generating random secrets in $(SECRETS)/$(RESET)\n"; \
		openssl rand -base64 24 | tr -d '\n' > $(SECRETS)/db_root_password.txt; \
	fi
	@if [ ! -f $(SECRETS)/db_password.txt ]; then \
		openssl rand -base64 24 | tr -d '\n' > $(SECRETS)/db_password.txt; \
	fi
	@if [ ! -f $(SECRETS)/ftp_password.txt ]; then \
		openssl rand -base64 18 | tr -d '\n' > $(SECRETS)/ftp_password.txt; \
	fi
	@if [ ! -f $(SECRETS)/credentials.txt ]; then \
		{ \
			printf 'WP_ADMIN_PASSWORD=%s\n' "$$(openssl rand -base64 18 | tr -d '\n')"; \
			printf 'WP_USER_PASSWORD=%s\n'  "$$(openssl rand -base64 18 | tr -d '\n')"; \
		} > $(SECRETS)/credentials.txt; \
	fi
	@chmod 600 $(SECRETS)/*.txt

## Add "127.0.0.1 $(DOMAIN_NAME)" to /etc/hosts (needs sudo)
hosts:
	@if grep -q "$(DOMAIN_NAME)" /etc/hosts; then \
		printf "$(GREEN)==> $(DOMAIN_NAME) is already in /etc/hosts$(RESET)\n"; \
	else \
		printf "$(BLUE)==> Adding $(DOMAIN_NAME) to /etc/hosts$(RESET)\n"; \
		echo "127.0.0.1 $(DOMAIN_NAME)" | sudo tee -a /etc/hosts > /dev/null; \
	fi

# --------------------------------------------------------------- introspection

ps status:
	@$(COMPOSE) --profile bonus ps

logs:
	@$(COMPOSE) --profile bonus logs -f --tail=100

# -------------------------------------------------------------------- cleaning

## Remove containers, images and networks (host data is kept)
clean: down
	@printf "$(YELLOW)==> Removing images and networks$(RESET)\n"
	@$(COMPOSE) --profile bonus down --rmi all --remove-orphans 2>/dev/null || true

## Remove everything, including the named volumes and the host data
fclean: clean
	@printf "$(YELLOW)==> Removing named volumes$(RESET)\n"
	@for v in $(VOLUMES); do docker volume rm -f $$v > /dev/null 2>&1 || true; done
	@printf "$(YELLOW)==> Removing $(DATA_PATH) content$(RESET)\n"
	@for v in $(VOLUMES); do \
		sudo rm -rf "$(DATA_PATH)/$$v" 2>/dev/null || rm -rf "$(DATA_PATH)/$$v"; \
	done

## Nuke every unused docker object on the machine
prune: fclean
	@docker system prune -af --volumes

help:
	@printf "$(BLUE)Inception - available targets$(RESET)\n"
	@printf "  make            build + run everything (mandatory + bonus)\n"
	@printf "  make mandatory  build + run only nginx / wordpress / mariadb\n"
	@printf "  make setup      create data dirs, .env and secrets\n"
	@printf "  make hosts      register $(DOMAIN_NAME) in /etc/hosts\n"
	@printf "  make down       stop and remove the containers\n"
	@printf "  make logs       follow the logs\n"
	@printf "  make ps         list the containers\n"
	@printf "  make clean      + remove images\n"
	@printf "  make fclean     + remove volumes and host data\n"
	@printf "  make re         fclean then rebuild\n"
	@printf "\n  Override the login with: make LOGIN=wil\n"
