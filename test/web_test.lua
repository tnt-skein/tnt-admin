--- Тесты страниц панели: их рисует узел, а не браузер.
---
--- Проверяется то, что видит оператор: страница раздела отвечает
--- разметкой, отбор — это адрес, действие — обычная форма, а файлы
--- панели раздаёт она сама. Разметку целиком сверять нечего: её правят
--- чаще, чем правила, — а вот то, что на странице видны имена узлов
--- и что действие доехало до кластера, обязано держаться.

local json = require('json')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.admin.routes.web')

--- Файлы панели: две строки вместо собранного стиля и сценария.
local PANEL = {
    ['panel.css'] = ':root { --tnt: 1 }',
    ['panel.js'] = 'const REFRESH_MS = 5000;',
}

---@type TntAdminPanel
local panel

--- С чем звали действие.
---@type table
local asked

g.before_each(function()
    helper.load('tnt.admin.app.support.root')

    asked = {}
    panel = helper.panel({
        panel = PANEL,

        snapshot = function()
            return {
                generation = 1,
                instances = {
                    ['storage-001-a'] = {
                        name = 'storage-001-a',
                        replicaset_name = 'storage-001',
                        reachable = true,
                        status = 'running',
                        ro = false,
                        memory = {},
                    },
                },
                replicasets = {
                    ['storage-001'] = { name = 'storage-001', instances = { 'storage-001-a' } },
                },
            }
        end,

        issues = function()
            return { { id = 'memory:storage-001-a', rule = 'memory', severity = 'warning', message = 'тесно' } }
        end,

        act = function(action, targets, identity, confirmation)
            asked = { action = action, targets = targets, identity = identity, confirmation = confirmation }

            return { status = 'complete', succeeded = targets, failed = {} }
        end,
    })
end)

g.after_each(function()
    helper.unload()
end)

g.test_every_section_answers_with_a_page = function()
    -- Раздел, добавленный в список страниц, отвечает сам: адрес берётся
    -- оттуда же, откуда меню. Потоком идёт только журнал: его длину
    -- задаёт журнал, а не панель.
    for _, path in ipairs({ '/', '/cluster', '/issues', '/config', '/audit' }) do
        local response = panel.ask('GET', path)

        t.assert_equals(response.status, 200, path)
        t.assert_equals(response.headers['content-type'], 'text/html; charset=utf-8', path)
        t.assert_equals(type(response.body) == 'function', path == '/audit', path)
        t.assert_str_contains(helper.drained(response), '<!doctype html>')
    end
end

g.test_the_page_shows_the_nodes_of_the_cluster = function()
    local response = panel.ask('GET', '/cluster')

    t.assert_str_contains(response.body, 'storage-001-a')
    t.assert_str_contains(response.body, 'storage-001')
end

g.test_the_filter_of_the_page_is_its_address = function()
    -- Отбор — это адрес: страница, открытая по ссылке, выглядит так же,
    -- как после нажатия на кнопку отбора.
    local troubled = panel.ask('GET', '/cluster?filter=trouble')

    t.assert_equals(troubled.status, 200)
    t.assert_not_str_contains(troubled.body, 'storage-001-a')

    local all = panel.ask('GET', '/cluster?filter=all')

    t.assert_str_contains(all.body, 'storage-001-a')
end

g.test_an_action_travels_as_a_form_and_ends_with_a_redirect = function()
    -- Панель работает и без сценариев: действие — обычная форма, а после
    -- него переход, иначе обновление в браузере повторяло бы действие.
    local response = panel.ask(
        'POST',
        '/actions/run',
        'action=reload_config&targets=storage-001-a&reason=%D0%BF%D0%BE%D1%80%D0%B0&back=%2Fcluster',
        { headers = { ['content-type'] = 'application/x-www-form-urlencoded' } }
    )

    t.assert_equals(response.status, 302)
    t.assert_equals(response.headers.location, '/cluster')
    t.assert_equals(asked.action, 'reload_config')
    t.assert_equals(asked.targets, { 'storage-001-a' })
    t.assert_equals(asked.confirmation, { reason = 'пора' })
end

g.test_an_action_on_a_cluster_without_actions_only_returns = function()
    -- Кластер без действий: форма отвечает переходом, а не поломкой, —
    -- кнопки такой на странице и не будет, но адрес открывают и руками.
    local bare = helper.panel({})

    local response = bare.ask(
        'POST',
        '/actions/run',
        'action=reload_config&targets=a',
        { headers = { ['content-type'] = 'application/x-www-form-urlencoded' } }
    )

    t.assert_equals(response.status, 302)
    t.assert_equals(response.headers.location, '/')
end

g.test_the_files_of_the_panel_are_served_by_itself = function()
    local styles = panel.ask('GET', '/panel.css')

    t.assert_equals(styles.status, 200)
    t.assert_equals(styles.body, PANEL['panel.css'])
    t.assert_str_contains(styles.headers['content-type'], 'text/css')
end

g.test_an_unknown_address_is_a_refusal_and_not_a_page = function()
    -- Панель рисует страницы сама, и адрес, которого у неё нет, — это
    -- отказ: иначе ссылка с опечаткой открывала бы обзор с кодом 200.
    t.assert_equals(panel.ask('GET', '/nowhere').status, 404)
end

g.test_the_api_and_the_metrics_are_not_served_as_files = function()
    -- Раздача файлов не трогает пути API и выкладки метрик: клиент,
    -- ошибшийся в адресе API, должен получить отказ панели — тот самый,
    -- который читает её JS, — а не «нет такого файла».
    local api = panel.ask('GET', '/api/v1/nowhere')

    t.assert_equals(api.status, 404)
    t.assert_equals(api.headers['content-type'], 'application/json; charset=utf-8')
    t.assert_str_contains(api.body, '"error"')

    -- Выкладка метрик на этой панели не включена, и отвечает она
    -- отказом 501, а не поиском файла `metrics`.
    local metrics = panel.ask('GET', '/metrics')

    t.assert_equals(metrics.status, 501)
    t.assert_equals(metrics.headers['content-type'], 'application/json; charset=utf-8')
end

g.test_a_panel_without_files_still_draws_its_pages = function()
    -- Файлов панели может не быть вовсе — например, в проверке: страницы
    -- рисует узел, и без стилей они остаются страницами.
    local bare = helper.panel({})

    t.assert_equals(bare.ask('GET', '/').status, 200)
    t.assert_equals(bare.ask('GET', '/panel.css').status, 404)
end

g.test_a_file_the_panel_has_not_is_refused_by_its_own_catalog = function()
    -- Промах по файлу рисует каталог отказов панели, как и всякий её
    -- отказ: JS панели читает то же тело, что на промах по адресу,
    -- а браузер получает страницу 404, а не JSON роутера.
    local api = panel.ask('GET', '/нет.css')
    local address = panel.ask('GET', '/api/v1/nowhere')

    t.assert_equals(api.status, 404)
    t.assert_equals(json.decode(api.body), { error = { status = 404, message = 'нет такого адреса' } })
    t.assert_equals(json.decode(api.body), json.decode(address.body))

    local page = panel.ask('GET', '/нет.css', nil, { headers = { accept = 'text/html' } })

    t.assert_equals(page.status, 404)
    t.assert_str_contains(page.headers['content-type'], 'text/html')
    t.assert_str_contains(page.body, '<!doctype html>')
end

-- ── Права на страницах ───────────────────────────────────────────────

--- Форма действия так, как её шлёт страница.
local FORM = 'action=reload_config&targets=storage-001-a&back=%2Fcluster'

--- Панель, где вход отдаёт названную личность.
---@param identity table
---@return TntAdminPanel
local function entered(identity)
    return helper.panel({
        snapshot = function()
            return { generation = 1, instances = {}, replicasets = {} }
        end,
        config = function()
            return { credentials = { users = { admin = {} } } }
        end,
        audit = function()
            local done = false

            return function()
                if done then
                    return nil
                end

                done = true

                return '{"id":1,"ts":1789760635145018,"user":"admin","action":"panel.reload_config.finished",'
                    .. '"scope":"storage-001-a"}\n'
            end
        end,
        act = function(action, targets)
            asked = { action = action, targets = targets }

            return { status = 'complete', succeeded = targets, failed = {} }
        end,
        authorize = function()
            return identity
        end,
    })
end

--- Разобранное тело отказа.
---@param response table
---@return table
local function refusal(response)
    return json.decode(response.body)
end

--- Отправляет форму действия.
---@param to TntAdminPanel
---@return table
local function submitted(to)
    return to.ask(
        'POST',
        '/actions/run',
        FORM,
        { headers = { ['content-type'] = 'application/x-www-form-urlencoded' } }
    )
end

g.test_the_observer_sees_the_cluster_but_not_the_configuration_or_the_log = function()
    -- Страница показывает то же, что API, и право у них одно: иначе
    -- страница стала бы дверью в обход API.
    local observer = entered({ username = 'наблюдатель', readonly = true })

    for _, path in ipairs({ '/', '/cluster', '/issues' }) do
        t.assert_equals(observer.ask('GET', path).status, 200, path)
    end

    local config = observer.ask('GET', '/config')

    t.assert_equals(config.status, 403)
    t.assert_equals(refusal(config), {
        error = {
            status = 403,
            message = 'у вас нет права смотреть конфигурацию кластера',
        },
    })
    t.assert_not_str_contains(config.body, 'credentials')

    local log = observer.ask('GET', '/audit')

    t.assert_equals(log.status, 403)
    t.assert_equals(
        refusal(log),
        { error = { status = 403, message = 'у вас нет права читать журнал аудита' } }
    )
end

g.test_the_observer_cannot_act_with_a_form_either = function()
    -- Форма — вторая дверь к тому же действию, что и API, и право у неё
    -- то же: наблюдателю отказ, и до кластера действие не доезжает.
    local response = submitted(entered({ username = 'наблюдатель', readonly = true }))

    t.assert_equals(response.status, 403)
    t.assert_equals(
        refusal(response),
        { error = { status = 403, message = 'у вас нет права менять кластер' } }
    )
    t.assert_equals(asked, {})
end

g.test_the_admin_acts_and_reads_the_configuration_but_the_log_needs_its_sign = function()
    local admin = entered({ username = 'admin', readonly = false })

    t.assert_equals(admin.ask('GET', '/config').status, 200)
    t.assert_equals(admin.ask('GET', '/audit').status, 403)

    local response = submitted(admin)

    t.assert_equals(response.status, 302)
    t.assert_equals(asked, { action = 'reload_config', targets = { 'storage-001-a' } })
end

g.test_the_auditor_reads_the_log_page = function()
    local log = entered({ username = 'аудитор', readonly = true, audit = true }).ask('GET', '/audit')

    -- Страница идёт потоком, и прокси просят не копить её: иначе первая
    -- строка дошла бы до браузера вместе с последней.
    t.assert_equals(log.status, 200)
    t.assert_type(log.body, 'function')
    t.assert_equals(log.headers['x-accel-buffering'], 'no')
    t.assert_equals(log.headers['content-length'], nil)

    local page = helper.drained(log)

    -- Колонки — поля строки выгрузки: кто, что, над чем и когда;
    -- отметка времени в микросекундах показана датой.
    t.assert_str_contains(page, '<td class="font-monospace small">admin</td>')
    t.assert_str_contains(page, '<td>panel.reload_config.finished</td>')
    t.assert_str_contains(page, '>storage-001-a</td>')
    t.assert_str_contains(page, os.date('%d.%m.%Y %H:%M:%S', 1789760635))
    t.assert_str_contains(page, 'записей на странице: 1')
    t.assert_not_str_contains(page, 'дальше')
end

--- Панель аудитора над журналом из названных кусков.
---@param pieces string[]
---@return TntAdminPanel
local function audited(pieces)
    return helper.panel({
        audit = function()
            local index = 0

            return function()
                index = index + 1

                return pieces[index]
            end
        end,
        authorize = function()
            return { username = 'аудитор', readonly = true, audit = true }
        end,
    })
end

g.test_the_log_page_links_to_the_next_page_beyond_its_limit = function()
    local rows = {}

    for id = 1, 1001 do
        table.insert(rows, ('{"id":%d,"action":"login"}\n'):format(id))
    end

    local page = helper.drained(audited({ table.concat(rows) }).ask('GET', '/audit?from_id=&to_id=2000'))

    -- Граница отрезка уходит в ссылку, а пустое поле формы — не отбор.
    t.assert_str_contains(page, 'записей на странице: 1000')
    t.assert_str_contains(page, 'href="/audit?from_id=1001&amp;to_id=2000"')
    t.assert_str_contains(page, 'value="2000"')
end

g.test_the_log_page_takes_the_same_range_as_the_export = function()
    -- Страница и выгрузка читают один журнал: отрезок, который одна
    -- принимает, а другая отвергает, выглядел бы поломкой. Отказ страницы —
    -- теми же словами, что у выгрузки.
    local auditor = audited({ '{"id":1,"action":"login"}\n' })
    local edge = helper.drained(auditor.ask('GET', '/audit?from_id=99999999999999'))

    t.assert_str_contains(edge, 'записей на странице: 1')

    local beyond = '?from_id=100000000000000&to_id=0'
    local page = helper.drained(auditor.ask('GET', '/audit' .. beyond))
    ---@type table<string, string>
    local fields = refusal(auditor.ask('GET', '/api/v1/audit' .. beyond)).error.fields

    t.assert_str_contains(page, 'отбор записей журнала не разобран')
    t.assert_str_contains(page, 'from_id ' .. fields.from_id)
    t.assert_str_contains(page, 'to_id ' .. fields.to_id)
    t.assert_not_str_contains(page, 'записей на странице')
end

g.test_pages_and_the_form_need_a_login_before_any_right = function()
    -- Опознавание стоит и на страницах, и первым: страница показывает
    -- кластер, а гостю, у которого прав нет вовсе, отвечают «войдите»,
    -- а не «нет права».
    local closed = helper.panel({
        act = function(action)
            asked = { action = action }

            return { status = 'complete' }
        end,
        authorize = function()
            return nil, 'войдите в панель'
        end,
    })

    for _, path in ipairs({ '/', '/cluster', '/issues', '/config', '/audit' }) do
        local response = closed.ask('GET', path)

        t.assert_equals(response.status, 401, path)
        t.assert_equals(
            refusal(response),
            { error = { status = 401, message = 'войдите в панель' } },
            path
        )
    end

    t.assert_equals(submitted(closed).status, 401)
    t.assert_equals(asked, {})
end
