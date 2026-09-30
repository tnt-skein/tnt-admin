--- Живая сверка толчка обзора с официальным клиентом `centrifuge-js`.
---
--- Свои проверки гоняют протокол строками JSON (`live_test.lua`) и могли
--- бы сойтись с узлом в общей ошибке. Здесь панель слушает тот же клиент,
--- что в браузере у оператора: он подписывается на обзор, получает
--- нынешний обзор в ответе на подписку и следующий снимок толчком,
--- без опроса, а гость получает отказ 101 и не переподключается.
--- Клиент `centrifuge` 5.7.4 ставит `make deps`; без Node или без клиента
--- проверка пропускается.

local json = require('json')
local fiber = require('fiber')
local t = require('luatest')

local helper = dofile('test/helper.lua')

--- Процессы — фасадом `tnt-process`: он ищет программу по `PATH` и читает
--- вывод со сроком, не останавливая узел.
local process = helper.process()

local g = t.group('tnt.admin.live.client')

--- Сценарий клиента: всё, что увидел, — одной строкой JSON в конце.
local SCRIPT = [[
const { Centrifuge } = require('centrifuge');
const seen = { publications: [], errors: [], connecting: 0 };
const client = new Centrifuge(process.argv[1], {
    websocket: WebSocket, timeout: 2000, minReconnectDelay: 100, maxReconnectDelay: 200,
});
const finish = () => { console.log(JSON.stringify(seen)); process.exit(0); };
client.on('connecting', () => { seen.connecting += 1; });
client.on('error', (ctx) => { seen.errors.push(ctx.error); });
client.on('disconnected', (ctx) => { seen.disconnected = { code: ctx.code, reason: ctx.reason }; finish(); });
const overview = client.newSubscription('overview');
overview.on('subscribed', (ctx) => { seen.subscribed = ctx.data.cluster.generation; });
overview.on('publication', (ctx) => {
    seen.publications.push(ctx.data.cluster.generation);
    if (seen.publications.length === 2) finish();
});
overview.subscribe();
client.connect();
setTimeout(finish, 8000);
]]

---@type any
local httpd

--- Есть ли Node со встроенным WebSocket и клиент Centrifugo.
---@return boolean
local function client_ready()
    local check = "require.resolve('centrifuge'); process.exit(typeof WebSocket === 'function' ? 0 : 1)"
    local result = process.run({ 'node', '-e', check }, { timeout = 10 })

    return result ~= nil and result.code == 0
end

--- Поднимает панель на случайном порту и отдаёт адрес её точки толчка.
---@param source table
---@return string
local function serving(source)
    local port

    httpd, port = helper.serve(source)

    return ('ws://127.0.0.1:%d/connection/websocket'):format(port)
end

--- Что увидел клиент, поговорив с панелью.
---@param url string
---@return table
local function seen_by_client(url)
    local result = assert(process.run({ 'node', '-e', SCRIPT, url }, { timeout = 15 }))

    return json.decode(result.stdout)
end

g.before_all(function()
    g.ready = client_ready()
end)

g.before_each(function()
    helper.load('tnt.admin.app.support.root')
end)

g.after_each(function()
    helper.close(httpd)
    httpd = nil
end)

g.test_a_new_snapshot_reaches_centrifuge_js_without_polling = function()
    t.skip_if(not g.ready, 'нет Node с клиентом centrifuge (make deps)')

    local generation, asked = 1, 0

    --- Извещение, отданное панелью; до подписки — пустое.
    ---@type fun()
    local notify = function() end

    local url = serving({
        snapshot = function()
            asked = asked + 1

            return { generation = generation, instances = {}, replicasets = {} }
        end,
        updates = function(given)
            notify = given

            return function() end
        end,
        authorize = function()
            return { username = 'ivan', readonly = true }
        end,
    })

    -- Кластер снят заново дважды, когда клиент уже подписан: ответ
    -- на подписку собирает обзор, и после него узел извещает о снимках.
    fiber.create(function()
        while asked == 0 do
            fiber.sleep(0.01)
        end

        for next_generation = 2, 3 do
            fiber.sleep(0.1)
            generation = next_generation
            notify()
        end
    end)

    local seen = seen_by_client(url)

    t.assert_equals(seen.subscribed, 1)
    t.assert_equals(seen.publications, { 2, 3 })
    t.assert_equals(seen.errors, {})
    t.assert_equals(seen.disconnected, nil)
    t.assert_equals(seen.connecting, 1)
end

g.test_a_guest_is_refused_with_101_and_does_not_come_back = function()
    t.skip_if(not g.ready, 'нет Node с клиентом centrifuge (make deps)')

    local url = serving({
        snapshot = function()
            return { generation = 1 }
        end,
        updates = function()
            return function() end
        end,
        authorize = function()
            return nil, 'войдите в панель'
        end,
    })

    local seen = seen_by_client(url)

    t.assert_equals(seen.disconnected, { code = 101, reason = 'unauthorized' })
    t.assert_equals(
        seen.connecting,
        1,
        'после отказа 101 клиент не переподключается'
    )
    t.assert_equals(seen.subscribed, nil)
    t.assert_equals(seen.publications, {})
end
