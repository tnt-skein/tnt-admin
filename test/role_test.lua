--- Тесты роли панели: что она отдаёт ядру и что берёт по соглашению.
---
--- Настоящего `roles.httpd` здесь нет: он есть только в поднятом кластере,
--- а роль обязана быть проверяемой на границе — по тому, какой сервер
--- она заняла, чем ответила и что осталось на сервере после снятия.
--- Мир вокруг роли — тот же двойник, которым проверяется ядро.

local t = require('luatest')

local helper = dofile('test/helper.lua')
local testing = helper.testing

local g = t.group('tnt.admin.role')

--- Записи журнала: роль называет в нём, чем панель питается.
local journal = testing.capture_log()

---@type any
local admin

---@type TntKernelWorld
local world

--- Ответ панели на запрос по её адресу.
---@param path string
---@return table
local function asked(path)
    return world.server.options.handler(world.server, helper.incoming({ method = 'GET', path = path }))
end

--- Записи журнала, начинающиеся с этих слов.
---@param message string
---@return table[]
local function written_all(message)
    local found = {}

    for _, entry in ipairs(journal.records()) do
        if entry.record.message:find(message, 1, true) == 1 then
            table.insert(found, entry.record)
        end
    end

    return found
end

--- Первая запись журнала с этими словами: её поля и само сообщение.
---@param message string
---@return table
local function written(message)
    local found = written_all(message)
    local first = found[1]

    t.assert_not_equals(first, nil, ('в журнале нет записи «%s»'):format(message))

    ---@cast first table
    local record = first.fields or {}

    record.message = first.message

    return record
end

g.before_each(function()
    world = helper.world()
    admin = helper.role(world)

    journal.forget()
end)

g.after_each(function()
    admin.stop()
    helper.unload()
end)

g.after_all(function()
    journal.release()
end)

g.test_the_panel_takes_its_own_server = function()
    -- Не `default`: там обычно стоит приложение, и молчаливое умолчание
    -- отняло бы у него обработчик при первом же включении панели.
    admin.apply()

    t.assert_equals(world.requested, 'admin')
    t.assert_equals(asked('/api/v1/cluster').status, 200)
end

g.test_a_named_server_is_taken = function()
    admin.apply({ server = 'панель' })

    t.assert_equals(world.requested, 'панель')
end

g.test_a_missing_server_is_named_in_the_refusal = function()
    world.server = nil

    t.assert_error_msg_contains('сервер admin не найден', admin.apply)
end

g.test_stopping_gives_the_handler_back = function()
    -- Сервер живёт у roles.httpd и панель переживает: без возврата он
    -- продолжал бы отвечать ею и после того, как роль убрали.
    local before = world.server.options.handler

    admin.apply()

    t.assert_not_equals(world.server.options.handler, before)

    admin.stop()

    t.assert_is(world.server.options.handler, before)
    t.assert_equals(world.server.stopped, false, 'чужой сервер не закрывают')
end

g.test_its_own_port_raises_its_own_server = function()
    -- Порт задан приложением — панель поднимает свой сервер ядром
    -- и ни с кем его не делит.
    admin.apply({ listen = '127.0.0.1:8081' })

    t.assert_equals(world.served, { host = '127.0.0.1', port = 8081 })
    t.assert_equals(world.requested, nil, 'сервер roles.httpd не спрашивали')
    t.assert_equals(world.server.started, true)
    t.assert_equals(asked('/api/v1/cluster').status, 200)
end

g.test_its_own_server_is_closed_on_stop = function()
    -- Свой сервер не возвращается, а закрывается: кроме панели, его
    -- никто не поднимал.
    admin.apply({ listen = '8081' })
    admin.stop()

    t.assert_equals(world.server.stopped, true)
end

g.test_the_pages_of_the_panel_are_drawn_by_the_node = function()
    -- Страницы рисует узел шаблонизатором из раскладки пакета: панель
    -- работает и без сценариев.
    admin.apply()

    local page = asked('/')

    t.assert_equals(page.status, 200)
    t.assert_str_contains(page.body, 'Обзор')
end

g.test_the_files_of_the_panel_are_served_by_itself = function()
    -- Файлы едут вместе с кодом: отдельного веб-сервера для статики нет,
    -- и расхождению версий панели и узла взяться неоткуда.
    admin.apply()

    local file = asked('/panel.css')

    t.assert_equals(file.status, 200)
    t.assert_str_contains(file.headers['content-type'], 'text/css')
end

g.test_without_an_account_the_panel_shows_no_actions = function()
    -- Звать действия наблюдателем нельзя: узел откажет «нет права»,
    -- и кнопка обещала бы то, чего не будет.
    admin.apply()

    local response = asked('/api/v1/capabilities')
    ---@type any
    local shown = require('json').decode(response.body)

    t.assert_equals(response.status, 200)
    t.assert_equals(shown, {
        version = 1,
        failover = false,
        config_rollout = false,
        authenticated = false,
        actions = {},
    })
end

g.test_the_panel_names_the_actions_the_cluster_can_do = function()
    -- Что кластер умеет, решают установленные рядом пакеты: панель
    -- показывает их действия и не показывает кнопок, которых нет.
    admin.apply({ actions = { login = 'maintenance', password = 'секрет' } })

    local response = asked('/api/v1/capabilities')
    ---@type any
    local shown = require('json').decode(response.body)

    t.assert_equals(response.status, 200)
    t.assert_equals(shown.failover, false)
    t.assert_equals(shown.config_rollout, false)
    t.assert_equals(shown.authenticated, false)
    t.assert_items_include(shown.actions, { 'reload_config', 'restart_replication' })
    t.assert_equals(
        written('панель питается').sources,
        'actions, audit, audit_verify, filter, issues, snapshot, suggestions, updates'
    )
end

g.test_the_log_names_what_the_panel_got = function()
    -- Умолчание не должно быть молчаливым: по журналу видно, чем панель
    -- питается на этом узле. Имена по алфавиту: запись одна и та же
    -- от применения к применению, и глазами её сверять можно.
    admin.apply()

    t.assert_equals(
        written('панель питается').sources,
        'audit, audit_verify, filter, issues, snapshot, suggestions, updates'
    )
end

g.test_a_source_turned_off_does_not_reach_the_panel = function()
    -- Диагностика стоит на узле ради соседа, а показывать её панель
    -- не должна: выключенный источник она считает отсутствующим.
    admin.apply({
        sources = { snapshot = false, issues = false, suggestions = false, filter = false, updates = false },
    })

    t.assert_equals(written('панель питается').sources, 'audit, audit_verify')
end

g.test_a_single_source_is_named_alone = function()
    -- Узел, где рядом стоит одна диагностика: перечень из одного имени —
    -- это тоже перечень, а не «ничего».
    admin.apply({
        sources = {
            issues = false,
            suggestions = false,
            filter = false,
            audit = false,
            audit_verify = false,
            updates = false,
        },
    })

    t.assert_equals(written('панель питается').sources, 'snapshot')
end

g.test_the_log_says_plainly_when_nothing_was_found = function()
    -- Панель на голом узле: пустой перечень читался бы как обрыв записи,
    -- а «ничего» — это ответ.
    admin.apply({
        sources = {
            snapshot = false,
            issues = false,
            suggestions = false,
            filter = false,
            audit = false,
            audit_verify = false,
            updates = false,
        },
    })

    t.assert_equals(written('панель питается').sources, 'ничего')
end

g.test_the_panel_starts_the_walk_when_it_is_given_an_account = function()
    -- Снимок кластера кто-то должен снимать: на узле, где панель стоит
    -- одна, — она сама, если ей дали учётку наблюдателя.
    local watch = testing.module('tnt.admin.app.services.watch')
    ---@type any
    local walked = { started = 0, stopped = 0, configured = nil }

    watch._set_source({
        cluster = function()
            return {
                configure = function(opts)
                    walked.configured = opts
                end,
                start = function()
                    walked.started = walked.started + 1
                end,
                stop = function()
                    walked.stopped = walked.stopped + 1
                end,
                status = function()
                    return { running = walked.started > walked.stopped }
                end,
            }
        end,
    })

    admin.apply({ watch = { login = 'health', password = 'секрет' } })

    t.assert_equals(walked.started, 1)
    t.assert_equals(walked.configured.login, 'health')
    t.assert_str_contains(written('обход кластера заведён').message, 'health')

    -- Снятая роль уносит за собой только свой обход.
    admin.stop()

    t.assert_equals(walked.stopped, 1)
end

g.test_the_panel_pushes_the_overview_and_stops_with_the_role = function()
    -- Диагностика рядом объявляет новые снимки событием: у роли есть
    -- точка толчка, и вход её не закрывает — рукопожатие без Upgrade
    -- отвечает 426 от самой точки. Снятая роль снимает и подписку
    -- на снимки: ядро закрывает точку, отключая роутер.
    local sources = testing.module('tnt.admin.app.services.sources')
    local watched = { registered = 0, unregistered = 0 }

    sources._set_source({
        watch = function()
            watched.registered = watched.registered + 1

            return {
                unregister = function()
                    watched.unregistered = watched.unregistered + 1
                end,
            }
        end,
    })

    admin.apply()

    t.assert_equals(asked('/connection/websocket').status, 426)
    t.assert_equals(watched.registered, 1)

    admin.stop()

    t.helpers.retrying({ timeout = 2 }, function()
        t.assert_equals(watched.unregistered, 1)
    end)
end

g.test_without_an_account_the_panel_walks_nowhere = function()
    -- Панель показывает то, что собрал кто-то другой: без учётки она
    -- обход не заводит и о нём не пишет.
    admin.apply()

    t.assert_equals(#written_all('обход кластера заведён'), 0)
end

g.test_an_unknown_setting_is_refused = function()
    -- Настройка с опечаткой иначе просто не применилась бы, а оператор
    -- узнал бы об этом по пустой панели.
    t.assert_error_msg_contains('ключа «serevr» нет', admin.validate, { serevr = 'admin' })
end

g.test_a_wrong_setting_is_refused = function()
    t.assert_error_msg_contains('tnt.admin.server', admin.validate, { server = 42 })
end

g.test_no_settings_at_all_are_allowed = function()
    -- Раздел роли необязателен: панель со своими умолчаниями — рабочая.
    admin.validate()
end

g.test_the_role_depends_on_the_http_server = function()
    -- Без объявления ядро подняло бы панель раньше сервера, и вставать
    -- ей было бы некуда.
    t.assert_equals(admin.dependencies, { 'roles.httpd' })
end

g.test_the_layout_of_the_package_is_taken_by_convention = function()
    -- Раскладка панели — та же, что у всякого приложения набора, только
    -- внутри пакета: провайдеры, маршруты и страницы находятся сами,
    -- и забыть про новый файл `routes/` нельзя.
    local layout = admin.layout()

    t.assert_equals(layout.routes, { 'tnt.admin.routes.api', 'tnt.admin.routes.web' })
    t.assert_equals(layout.providers, 'tnt.admin.bootstrap.providers')
    t.assert_str_contains(layout.views, 'resources/views')
end
