--- Тесты толчка обзора: узел сам публикует обзор, браузер подписан.
---
--- Панель поднимается на настоящем порту, а клиентом ходит WebSocket
--- пакета `tnt-websocket`: команды Centrifugo идут строками JSON, как их
--- шлёт `centrifuge-js`. Извещение о новом снимке — двойник источника:
--- проверка сама решает, когда кластер снят заново, и видит, когда панель
--- подписалась и когда отписалась. С официальным клиентом панель
--- сверяется отдельно (`live_client_test.lua`).

local json = require('json')
local t = require('luatest')

local helper = dofile('test/helper.lua')
local testing = helper.testing

local g = t.group('tnt.admin.app.services.live')

--- Записи журнала: отказ толчка пишется туда, а не бросается.
local journal = testing.capture_log()

---@type any
local live

---@type any
local httpd

---@type string
local url

--- Порт панели, поднятой `serving`: по нему проверка спрашивает и API.
---@type integer
local port

---@class TntAdminLiveState
---@field generation integer Номер обхода нынешнего снимка
---@field uptime number Время работы узла в снимке
---@field broken boolean Отказывает ли снимок
---@field subscribed integer Сколько раз панель подписалась на снимки
---@field released integer Сколько раз отписалась
---@field notify fun() Извещение, отданное панелью; до подписки — пустое

---@type TntAdminLiveState
local state

--- Источники панели: снимок из одного узла и извещение-двойник.
---@param extra table|nil Источники поверх
---@return table
local function source_of(extra)
    local source = {
        snapshot = function()
            if state.broken then
                error('спейса нет')
            end

            return {
                generation = state.generation,
                instances = {
                    ['storage-001-a'] = { name = 'storage-001-a', reachable = true, uptime = state.uptime },
                },
                replicasets = { ['storage-001'] = { instances = { 'storage-001-a' } } },
            }
        end,

        updates = function(notify)
            state.subscribed = state.subscribed + 1
            state.notify = notify

            return function()
                state.released = state.released + 1
            end
        end,
    }

    for name, value in pairs(extra or {}) do
        source[name] = value
    end

    return source
end

--- Поднимает панель на случайном порту.
---@param source table
local function serving(source)
    httpd, port = helper.serve(source)
    url = ('ws://127.0.0.1:%d%s'):format(port, live.PATH)
end

--- Открывает соединение WebSocket с точкой.
---@param address string|nil
---@return any
local function dial(address)
    return helper.dial(address or url)
end

local heard = helper.heard
local call = helper.call

--- Соединение, подписанное на обзор, и ответ на подписку.
---@return any ws
---@return any reply
local function subscribed()
    local ws = dial()

    call(ws, '{"id":1,"connect":{}}')

    return ws, call(ws, ('{"id":2,"subscribe":{"channel":"%s"}}'):format(live.CHANNEL))
end

--- Записи журнала, начинающиеся с этих слов: уровень и сама запись.
---@param message string
---@return table[]
local function written(message)
    local found = {}

    for _, entry in ipairs(journal.records()) do
        if entry.record.message:find(message, 1, true) == 1 then
            table.insert(found, entry)
        end
    end

    return found
end

g.before_each(function()
    helper.load('tnt.admin.app.support.root')
    live = testing.module('tnt.admin.app.services.live')

    state = {
        generation = 1,
        uptime = 60,
        broken = false,
        subscribed = 0,
        released = 0,
        notify = function() end,
    }
    journal.forget()
end)

g.after_each(function()
    helper.close(httpd)
    httpd = nil
end)

g.after_all(function()
    journal.release()
end)

g.test_without_updates_there_is_no_endpoint = function()
    -- Подписанный браузер ждал бы толчков, которых не будет: без
    -- извещения о снимках точки нет, и страница обновляется опросом.
    t.assert_equals(live.new({ snapshot = function() end }), nil)

    local panel = helper.panel({ snapshot = source_of().snapshot })

    t.assert_equals(panel.ask('GET', live.PATH).status, 404)
    t.assert_str_contains(panel.ask('GET', '/').body, 'data-live=""')
end

g.test_the_page_names_the_address_of_the_push = function()
    local panel = helper.panel(source_of())

    -- Адрес стоит в каркасе, а каркас у всех страниц один — и у журнала,
    -- который идёт потоком: его данные собираются тем же путём, а рисует
    -- их другой вид.
    for _, path in ipairs({ '/', '/cluster', '/issues', '/config', '/audit' }) do
        local page = helper.drained(panel.ask('GET', path))

        t.assert_str_contains(page, 'data-live="/connection/websocket"', false, path)
    end
end

g.test_the_endpoint_is_not_behind_the_login = function()
    -- Гость получает отказ Centrifugo, а не 401 на рукопожатии: после
    -- отказа кодом HTTP клиент переподключался бы без конца.
    local panel = helper.panel(source_of({
        authorize = function()
            return nil, 'войдите в панель'
        end,
    }))

    t.assert_equals(panel.ask('GET', '/').status, 401)
    t.assert_equals(panel.ask('GET', live.PATH).status, 426)
end

g.test_a_guest_gets_unauthorized_on_connect = function()
    local asked = {}

    serving(source_of({
        authorize = function(request)
            table.insert(asked, request.path)

            return nil, 'войдите в панель'
        end,
    }))

    local ws = dial()

    t.assert_equals(call(ws, '{"id":1,"connect":{}}'), {
        id = 1,
        error = { code = 101, message = 'unauthorized' },
    })
    t.assert_equals(asked, { live.PATH }, 'вход спрошен по запросу рукопожатия')
    ws:close()
end

g.test_an_operator_subscribes_and_gets_the_overview_at_once = function()
    serving(source_of({
        authorize = function(request)
            return { username = request.headers['x-operator'] or 'ivan', readonly = true }
        end,
    }))

    local ws, reply = subscribed()
    local overview = reply.subscribe.data

    t.assert_equals(reply.id, 2)
    t.assert_equals(overview.cluster.generation, 1)
    t.assert_equals(overview.cluster.servers[1].name, 'storage-001-a')
    t.assert_equals(overview.issues, {})
    t.assert_equals(overview.suggestions, {})
    ws:close()
end

g.test_the_channel_carries_the_body_of_the_api = function()
    -- В канал уходит выдача той же формы, что отвечает `GET /api/v1/overview`:
    -- клиент, который сначала спросил, а потом подписался, получает одно
    -- тело. Без формы пустой словарь ушёл бы в канал списком `[]`,
    -- а не `{}`, как его описывает описание API.
    serving(source_of())

    local ws = dial()

    call(ws, '{"id":1,"connect":{}}')
    ws:send(('{"id":2,"subscribe":{"channel":"%s"}}'):format(live.CHANNEL))

    local text = ws:receive(2).data
    ---@type any
    local asked = require('http.client').new():get(('http://127.0.0.1:%d/api/v1/overview'):format(port))

    t.assert_equals(asked.status, 200)
    t.assert_equals(json.decode(text).subscribe.data, json.decode(asked.body))
    t.assert_str_contains(asked.body, '"memory":{}')
    t.assert_str_contains(text, '"memory":{}')
    ws:close()
end

g.test_an_open_panel_lets_everyone_in = function()
    -- Без опознания панель открыта — и толчок тоже.
    serving(source_of())

    local ws = dial()
    local reply = call(ws, '{"id":1,"connect":{}}')

    t.assert_equals(reply.id, 1)
    t.assert_type(reply.connect.client, 'string')
    ws:close()
end

g.test_another_channel_is_unknown = function()
    serving(source_of())

    local ws = dial()

    call(ws, '{"id":1,"connect":{}}')

    t.assert_equals(call(ws, '{"id":2,"subscribe":{"channel":"secret"}}'), {
        id = 2,
        error = { code = 102, message = 'unknown channel' },
    })
    ws:close()
end

g.test_a_new_snapshot_reaches_the_subscriber = function()
    serving(source_of())

    local ws = subscribed()

    state.generation = 2
    state.uptime = 65
    state.notify()

    local push = heard(ws)

    t.assert_equals(push.push.channel, 'overview')
    t.assert_equals(push.push.pub.data.cluster.generation, 2)
    t.assert_equals(push.push.pub.data.cluster.servers[1].uptime, 65)
    ws:close()
end

g.test_the_same_snapshot_goes_out_once = function()
    -- Наблюдатель события отдаёт последнее значение сразу, как его
    -- завели: тот же снимок не уходит подписчику второй раз.
    serving(source_of())

    local ws = subscribed()

    state.generation = 2
    state.notify()
    state.notify()
    state.generation = 3
    state.notify()

    t.assert_equals(heard(ws).push.pub.data.cluster.generation, 2)
    t.assert_equals(heard(ws).push.pub.data.cluster.generation, 3)
    t.assert_equals(heard(ws, 0.1), nil)
    ws:close()
end

g.test_the_subscription_starts_with_the_first_handshake = function()
    -- К узлу, где панель никто не открывал, обзор не собирается
    -- на каждый обход.
    serving(source_of())

    t.assert_equals(state.subscribed, 0)

    local first = dial()
    local second = dial()

    t.assert_equals(state.subscribed, 1)
    first:close()
    second:close()
end

g.test_a_broken_overview_is_written_down = function()
    -- Извещение зовёт наблюдатель, и брошенное в нём не дошло бы
    -- ни до кого: отказ идёт в журнал, а подписчик ждёт следующего.
    serving(source_of())

    local ws = subscribed()

    state.broken = true
    state.generation = 2
    state.notify()

    ---@type any
    local entry = written('обзор кластера не собран')[1]

    t.assert_not_equals(entry, nil)
    t.assert_equals(entry.level, 'error')
    t.assert_str_contains(entry.record.fields.err, 'спейса нет')

    state.broken = false
    state.notify()

    t.assert_equals(heard(ws).push.pub.data.cluster.generation, 2)
    ws:close()
end

g.test_an_overview_json_cannot_carry_is_tried_again = function()
    -- Обзор, который не кодируется в JSON, не уходит никому, а номер его
    -- обхода не считается разосланным: тот же снимок, поправленный,
    -- уходит со следующим извещением.
    serving(source_of())

    local ws = subscribed()

    state.generation = 2
    state.uptime = 0 / 0
    state.notify()

    ---@type any
    local entry = written('обзор кластера не опубликован')[1]

    t.assert_not_equals(entry, nil)
    t.assert_equals(entry.level, 'warn')
    t.assert_str_contains(entry.record.fields.err, 'JSON')

    state.uptime = 70
    state.notify()

    t.assert_equals(heard(ws).push.pub.data.cluster.servers[1].uptime, 70)
    ws:close()
end

g.test_closing_releases_the_subscription_and_the_sessions = function()
    -- Ядро зовёт `close_all`, отключая роутер: сессии рвутся кодом
    -- Centrifugo «shutdown», и клиент переподключается к новому
    -- применению, а подписка на снимки снимается один раз.
    local endpoint = live.new(source_of())
    local router = testing.module('tnt.router')

    httpd = require('http.server').new('127.0.0.1', 0, { log_requests = false, log_errors = false })
    router.get(live.PATH, endpoint.handler)
    router.attach(httpd)
    httpd:start()

    local ws = dial(('ws://127.0.0.1:%d%s'):format(httpd.tcp_server:name().port, live.PATH))

    call(ws, '{"id":1,"connect":{}}')

    t.assert_equals(endpoint.close_all(endpoint, 1012, 'приложение перезапускается'), 1)
    t.assert_equals(state.released, 1)

    local _, err = heard(ws)

    t.assert_equals({ err.code, err.reason }, { 3001, 'shutdown' })

    -- Второе закрытие подписку не снимает заново, а рукопожатие после
    -- остановки её не заводит.
    t.assert_equals(
        endpoint.close_all(endpoint, 1001, 'приложение уходит с этого сервера'),
        0
    )
    t.assert_equals(state.released, 1)

    endpoint.handler({ method = 'GET', headers = {} })

    t.assert_equals(state.subscribed, 1)
end

g.test_closing_before_any_handshake_has_nothing_to_release = function()
    local endpoint = live.new(source_of())

    t.assert_equals(endpoint.close_all(endpoint, 1012, 'приложение перезапускается'), 0)
    t.assert_equals({ state.subscribed, state.released }, { 0, 0 })
end

g.test_the_endpoint_is_limited = function()
    -- Гость держал бы файберы узла: отказанный connect соединения
    -- не рвёт. Предел не даёт открыть их сколько угодно; здесь он снижен
    -- до одного, чтобы проверка не открывала сотни соединений.
    t.assert_equals(live.MAX_CONNECTIONS, 256)

    live.MAX_CONNECTIONS = 1

    serving(source_of())

    local first = dial()
    local second, err = testing.module('tnt.websocket').connect(url, { timeout = 2 })

    t.assert_equals(second, nil)
    t.assert_str_contains(tostring(err), '503')
    first:close()
end
