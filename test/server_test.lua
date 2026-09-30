--- Панель, поднятая на настоящем порту.
---
--- Всё остальное проверяется запросом-таблицей, и это правильно: так
--- проверка быстрая и в ней видно, что именно проверяется. Но панель,
--- безупречная на таблицах и неспособная ответить настоящему браузеру,
--- бесполезна — а разойтись они могут в мелочах: в том, как сервер отдаёт
--- путь, заголовки и тело, и в том, доезжает ли до входа адрес клиента.
---
--- Сервер поднимается тут же, на случайном порту: докер для этого не нужен,
--- и гейт от него не зависит.

local json = require('json')
local t = require('luatest')

local http_client = require('http.client')
local http_server = require('http.server')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.admin.server')

--- Файлы панели: две строки вместо собранного JS.
local PANEL = {
    ['index.html'] = '<!doctype html><title>панель</title>',
    ['app.js'] = 'const REFRESH_MS = 5000;',
}

--- Источники, с которыми панель поднимется на порту.
---@type table
local source

---@type any
local httpd

---@type string
local address

g.before_each(function()
    helper.load('tnt.admin.app.support.root')
    source = {}
end)

g.after_each(function()
    if httpd ~= nil then
        httpd:stop()
        httpd = nil
    end

    helper.unload()
end)

--- Называет источники, с которыми поднимется панель.
---@param given table
local function configure(given)
    source = given
end

--- Поднимает панель на случайном порту.
local function serving()
    httpd = http_server.new('127.0.0.1', 0, { log_requests = false, log_errors = false })

    helper.panel(source, httpd)
    httpd:start()

    address = ('http://127.0.0.1:%d'):format(httpd.tcp_server:name().port)
end

--- Запрос к поднятой панели.
---@param method string
---@param where string
---@param opts table|nil
---@return table
local function asked(method, where, opts)
    local given = opts or {}

    return http_client.new():request(method, address .. where, given.body, {
        headers = given.headers,
        timeout = 5,
    })
end

--- Снимок кластера из одного узла: по проводу проверяется дорога,
--- а не модель, и подробности снимка ей только мешают.
---@return table
local function snapshot()
    return {
        generation = 1,
        instances = { ['storage-001-a'] = { name = 'storage-001-a', reachable = true } },
        replicasets = { ['storage-001'] = { instances = { 'storage-001-a' } } },
    }
end

g.test_browser_walks_the_panel_addresses = function()
    configure({
        panel = PANEL,
        snapshot = snapshot,
        capabilities = function()
            return { failover = true, actions = { 'reload_config' } }
        end,
    })

    serving()

    local overview = asked('GET', '/api/v1/overview')

    t.assert_equals(overview.status, 200)
    t.assert_equals(overview.headers['content-type'], 'application/json; charset=utf-8')
    t.assert_equals(json.decode(overview.body).cluster.servers[1].name, 'storage-001-a')

    t.assert_equals(json.decode(asked('GET', '/api/v1/capabilities').body).failover, true)
    t.assert_equals(json.decode(asked('GET', '/api/v1/issues').body).issues, {})
end

g.test_the_files_of_the_panel_reach_the_browser = function()
    configure({ panel = PANEL })
    serving()

    t.assert_equals(asked('GET', '/app.js').body, 'const REFRESH_MS = 5000;')

    -- Страницы рисует узел, а не файл: адреса, которого у панели нет,
    -- браузер не получает с кодом 200.
    t.assert_equals(asked('GET', '/nodes').status, 404)
end

g.test_kept_file_is_not_sent_twice = function()
    configure({ panel = PANEL })
    serving()

    local first = asked('GET', '/app.js')

    t.assert_type(first.headers.etag, 'string')

    local again = asked('GET', '/app.js', { headers = { ['If-None-Match'] = first.headers.etag } })

    t.assert_equals(again.status, 304)
end

g.test_action_goes_through_the_wire_with_its_body = function()
    ---@type any
    local seen

    configure({
        act = function(action, targets, _, confirmation)
            seen = { action = action, targets = targets, key = confirmation.key }

            return { status = 'complete', succeeded = targets, failed = {}, summary = 'удалось' }
        end,
    })

    serving()

    local answer = asked('POST', '/api/v1/actions', {
        body = json.encode({
            action = 'reload_config',
            targets = { 'storage-001-a' },
            key = 'нажатие-17',
        }),
        headers = { ['Content-Type'] = 'application/json' },
    })

    t.assert_equals(answer.status, 200)
    t.assert_equals(seen.action, 'reload_config')
    t.assert_equals(seen.targets, { 'storage-001-a' })
    t.assert_equals(seen.key, 'нажатие-17')
    t.assert_equals(json.decode(answer.body).summary, 'удалось')
end

g.test_a_filter_goes_through_the_wire_with_its_brackets = function()
    -- Скобки меток клиент кодирует (`%5B`, `%5D`), а запятую списка —
    -- нет: до отбора обе записи обязаны доехать тем, что написал человек.
    ---@type any
    local seen

    configure({
        filter = function(selector)
            seen = selector

            return { { name = 'storage-001-a', labels = { zone = 'spb' } } }
        end,
    })

    serving()

    local answer = asked('GET', '/api/v1/instances?groups=routers,storages&labels%5Bzone%5D=spb')

    t.assert_equals(answer.status, 200)
    t.assert_equals(seen, { groups = { 'routers', 'storages' }, labels = { zone = 'spb' } })
    t.assert_equals(json.decode(answer.body).instances[1].labels, { zone = 'spb' })
end

g.test_address_of_the_client_reaches_the_login = function()
    -- Вход считает неудачные догадки по адресу, и адрес этот приносит
    -- сервер, а не тело запроса.
    ---@type any
    local seen

    configure({
        authenticate = function(username, _, request)
            seen = { username = username, host = request.peer.host }

            return { username = username }
        end,
    })

    serving()

    local answer = asked('POST', '/api/v1/login', {
        body = json.encode({ username = 'admin', password = 'верный' }),
    })

    t.assert_equals(answer.status, 200)
    t.assert_equals(seen.username, 'admin')
    t.assert_equals(seen.host, '127.0.0.1')
end

g.test_metrics_come_back_as_plain_text = function()
    configure({
        metrics = function()
            return 'cluster_up 1\n'
        end,
    })

    serving()

    local answer = asked('GET', '/metrics')

    t.assert_equals(answer.status, 200)
    t.assert_equals(answer.body, 'cluster_up 1\n')
    t.assert_str_contains(answer.headers['content-type'], 'version=0.0.4')
end

g.test_wrong_address_and_wrong_method_are_told_apart = function()
    configure({ panel = PANEL })
    serving()

    local missing = asked('GET', '/api/v1/nothing', { headers = { ['X-Request-Id'] = 'по-проводу-1' } })

    t.assert_equals(missing.status, 404)

    local refused = asked('DELETE', '/api/v1/cluster')

    t.assert_equals(refused.status, 405)
    t.assert_equals(refused.headers.allow, 'GET, HEAD, OPTIONS')

    -- 404 здесь отвечает раздача, 405 — сам роутер до маршрута, и оба
    -- идут через слои входа: номер запроса доезжает до клиента и по
    -- проводу — соседский как есть, а без него свой.
    t.assert_equals(missing.headers['x-request-id'], 'по-проводу-1')
    t.assert_type(refused.headers['x-request-id'], 'string')
end

g.test_fallen_source_does_not_take_the_node_down = function()
    -- Один запрос — одна беда: остальные обязаны ходить дальше, а наружу
    -- не должно уйти ни стека, ни текста внутреннего отказа.
    configure({
        snapshot = function()
            error('спейса нет')
        end,

        capabilities = function()
            return { failover = false }
        end,
    })

    serving()

    local broken = asked('GET', '/api/v1/cluster')

    t.assert_equals(broken.status, 500)
    t.assert_not_str_contains(broken.body, 'спейса нет')
    t.assert_not_str_contains(broken.body, 'stack traceback')

    t.assert_equals(asked('GET', '/api/v1/capabilities').status, 200)
end
