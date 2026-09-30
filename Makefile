# Проверки пакета: форматирование, линт, тесты, покрытие, мутанты.

LUATEST  := .rocks/bin/luatest
LUACHECK := .rocks/bin/luacheck
COVERAGE_MIN ?= 100

# luatest держит узлы в VARDIR и стирает этот каталог на старте. Умолчание —
# общий /tmp/t, а в окружении может стоять VARDIR другого проекта: прогон
# уносил бы чужие узлы и писал бы в чужой журнал. Правило то же, что
# у tnt-mutants, — проверки и мутационный прогон делят один каталог.
# Приставка держит значение непустым: пустой VARDIR luatest понял бы как
# текущий каталог и стёр бы репозиторий.
VARDIR := /tmp/t-$(shell printf '%s' "$$(pwd)" | cksum | cut -d' ' -f1)
export VARDIR

.PHONY: help
help: ## Список целей
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN { FS = ":.*?## " } { printf "  %-12s %s\n", $$1, $$2 }'

# cluacov считает исполняемые строки по байткоду: без него luacov относит
# попадание в выражение на несколько строк к последней из них, и первая
# строка константы числится непокрытой.
#
# cluacov собирается из C против своих копий заголовков LuaJIT, и копию
# он выбирает по LUAJIT_VERSION_NUM: Tarantool объявляет 20100, и берутся
# заголовки 2.1.0-beta3. В них GC64 на x86_64 включается только макросом
# LUAJIT_ENABLE_GC64 (на arm64 — всегда), а Tarantool собран с GC64. Без
# флага раскладка объектов у рока и у машины расходится, и cluacov падает
# segfault в l_deepactivelines — гейт покрытия и его проверка падают вместе
# с ним. На arm64 флаг ничего не меняет. Аргумент CFLAGS= заменяет значение
# luarocks целиком, поэтому -fPIC повторён: без него разделяемая библиотека
# не соберётся.
CLUACOV_CFLAGS := CFLAGS="-O2 -fPIC -DLUAJIT_ENABLE_GC64"

# Собранный cluacov проверяется сразу: подсказка нужна и тогда, когда
# рок роняет процесс, а не отвечает ошибкой. Скобки держат `||` на этой
# проверке — иначе подсказка печаталась бы и на отказе предыдущего шага.
CLUACOV_CHECK := { tarantool -e "local lines = require('cluacov.deepactivelines').get(loadstring('local a = 1\nreturn a')) \
	os.exit((lines[1] and lines[2]) and 0 or 1)" || \
	{ echo 'cluacov собран не под LuaJIT этого Tarantool: см. CLUACOV_CFLAGS в Makefile' >&2; false; }; }

# Рок http — с сервера Tarantool, раньше зависимостей: на нём стоят
# роутер и панель на настоящем порту, а под тем же именем в общем каталоге
# роков лежит другой пакет. Рок argparse — тоже раньше зависимостей
# и с luarocks.org: разбор команд узла закреплён на 0.7.2-1, а на сервере
# роков Tarantool по умолчанию выпуски кончаются на 0.6.0. И после
# luacheck: тот тянет argparse сам, модуль у обоих один —
# `require('argparse')`, — и в дереве должен остаться закреплённый выпуск.
#
# Сверх зависимостей пакета проверкам нужны соседи, которых панель берёт
# по имени: журнал аудита tnt-audit (узел журнала за проводом), действия
# tnt-ops и tnt-sharding с оценкой и воротами tnt-recovery — умолчания
# внешних зависимостей сверяются с тем, что находится по имени. Трассы
# tnt-trace и контекст запроса tnt-context проверки берут сами: номер
# трассы и запроса в журнале панели. Клиент centrifuge-js ставится
# в node_modules каталога, выпуском, с которым сверены поля ответов;
# без Node или без клиента живая сверка пропускается, а остальные идут.
.PHONY: deps
deps: ## Поставить зависимости пакета, соседей проверок, клиент centrifuge-js и инструменты проверок
	tt rocks install --server=https://luarocks.org luatest
	tt rocks install --server=https://luarocks.org luacheck 1.2.0
	tt rocks install --server=https://luarocks.org luacov 0.17.0
	tt rocks install --server=https://luarocks.org cluacov 1.0.0 $(CLUACOV_CFLAGS) && \
	$(CLUACOV_CHECK)
	tt rocks install --server=https://rocks.tarantool.org http
	tt rocks install --server=https://luarocks.org argparse 0.7.2-1
	tt rocks install --server=https://tnt-skein.github.io/rocks --only-deps tnt-admin-scm-1.rockspec
	tt rocks install --server=https://tnt-skein.github.io/rocks tnt-audit
	tt rocks install --server=https://tnt-skein.github.io/rocks tnt-context
	tt rocks install --server=https://tnt-skein.github.io/rocks tnt-ops
	tt rocks install --server=https://tnt-skein.github.io/rocks tnt-recovery
	tt rocks install --server=https://tnt-skein.github.io/rocks tnt-sharding
	tt rocks install --server=https://tnt-skein.github.io/rocks tnt-trace
	npm install --prefix . --no-save --no-package-lock --silent centrifuge@5.7.4

.PHONY: fmt
fmt: ## Отформатировать код
	stylua .

.PHONY: fmt-check
fmt-check: ## Проверить форматирование, ничего не меняя
	stylua --check .

.PHONY: lint
lint: ## Линт
	$(LUACHECK) . --formatter plain --codes

.PHONY: test
test: ## Прогон проверок
	$(LUATEST) test/

.PHONY: coverage
coverage: ## Проверки с покрытием и порогом
	mkdir -p var && rm -f var/luacov.stats.out
	$(LUATEST) test/ --coverage
	tarantool tools/coverage_gate.lua $(COVERAGE_MIN)

# Стили и сценарий панели собираются из ui/ в panel/ (`bun install`,
# `bun run build`), а оттуда пакуются в модуль: узел раздаёт панель
# из памяти процесса, и версии панели и узла разойтись негде.
.PHONY: panel
panel: ## Упаковать собранные файлы панели из panel/ в модуль
	tarantool tools/pack_panel.lua

# Описание API панели docs/api/panel.yaml собирается из её маршрутов, форм
# tnt-data и слов операций: руками его не правят.
.PHONY: api-spec
api-spec: ## Собрать описание API панели docs/api/panel.yaml из её кода
	tarantool tools/build_api_spec.lua

# Описание сличается с документом, собранным заново, а тела образцов
# отказа — со схемами описания. Упакованная панель сверяется с panel/:
# модуль собирается инструментом, а правится каталог, и забыть пересобрать
# легко — тогда узел отдаёт вчерашнюю панель.
.PHONY: lint-api
lint-api: ## Описание API совпадает с кодом, упакованная панель — с panel/
	tarantool tools/check_api_spec.lua
	tarantool tools/check_panel_bundle.lua

# Мутационное тестирование — утилитой tnt-mutants (github.com/tnt-skein/tnt-mutants).
# Упакованная панель и страницы шаблонов — данные и разметка, а не код:
# их мутировать нечего (mutants.conf).
.PHONY: mutants
mutants: ## Мутационное тестирование изменённых модулей
	tnt-mutants

.PHONY: mutants-all
mutants-all: ## Мутационное тестирование всех модулей
	tnt-mutants $(shell find tnt -name '*.lua' ! -name '*.thtml.lua' ! -path 'tnt/admin/public/*' | sort)

.PHONY: check
check: fmt-check lint lint-api test coverage ## Все проверки, кроме мутантов

.PHONY: clean
clean: ## Убрать рабочие каталоги
	rm -rf var
