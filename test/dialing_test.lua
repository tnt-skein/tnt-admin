--- Тесты связи с узлами: панель зовёт действия под своей учёткой.
---
--- Настоящих сокетов здесь нет: проверяется то, под какой учёткой панель
--- просит адрес, когда она переоткрывает соединение и что закрывает
--- за собой.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = t.group('tnt.admin.app.services.dialing')

---@type any
local dialing

--- Что спрашивали у конфигурации и что открывали.
---@type any
local seen

--- Ставит двойники конфигурации и клиента iproto.
---@param opts table|nil
local function armed(opts)
    local given = opts or {}

    seen = { asked = {}, opened = 0, closed = 0 }

    dialing._set_source({
        pool = function()
            return {
                peer_uri = function(name, credentials)
                    table.insert(seen.asked, { instance = name, login = credentials.login })

                    if given.broken then
                        return nil, 'конфигурация недоступна'
                    end

                    if given.uri == nil then
                        return nil, ('адрес инстанса %s не объявлен'):format(name)
                    end

                    return { uri = given.uri }
                end,
            }
        end,

        net_box = function()
            return {
                connect = function(uri)
                    seen.opened = seen.opened + 1

                    if given.unreachable then
                        error('связи нет')
                    end

                    return {
                        state = given.state or 'active',
                        uri = uri,
                        close = function()
                            seen.closed = seen.closed + 1
                        end,
                    }
                end,
            }
        end,
    })
end

g.before_each(function()
    dialing = helper.load('tnt.admin.app.services.dialing')
end)

g.after_each(function()
    helper.unload()
end)

g.test_the_address_is_asked_under_the_account_of_the_actions = function()
    -- Смотреть и менять — разные права: адрес запрашивается с той
    -- учёткой, под которой панель будет звать действие.
    armed({ uri = '127.0.0.1:3301' })

    local calls = dialing.new({ login = 'maintenance', password = 'секрет' })

    t.assert_not_equals(calls.connection('storage-001-a'), nil)
    t.assert_equals(seen.asked[1], { instance = 'storage-001-a', login = 'maintenance' })
end

g.test_an_open_connection_is_reused = function()
    -- Действие на кластере из десятка узлов иначе платило бы
    -- установлением связи за каждый узел и каждое нажатие.
    armed({ uri = '127.0.0.1:3301' })

    local calls = dialing.new({ login = 'maintenance' })

    local first = calls.connection('storage-001-a')
    local second = calls.connection('storage-001-a')

    t.assert_equals(seen.opened, 1)
    t.assert_is(second, first, 'второй вызов берёт то же соединение')
end

g.test_a_broken_connection_is_opened_again = function()
    armed({ uri = '127.0.0.1:3301', state = 'error' })

    local calls = dialing.new({ login = 'maintenance' })

    calls.connection('storage-001-a')
    calls.connection('storage-001-a')

    t.assert_equals(seen.opened, 2)
    t.assert_equals(seen.closed, 1, 'прежнее соединение закрыто, а не забыто')
end

g.test_a_node_without_an_address_is_named_in_the_refusal = function()
    armed({})

    local calls = dialing.new({ login = 'maintenance' })
    local connection, reason = calls.connection('нет-такого')

    t.assert_equals(connection, nil)
    t.assert_str_contains(reason, 'адрес инстанса нет-такого не объявлен')
end

g.test_a_configuration_that_throws_is_a_refusal_and_not_a_breakdown = function()
    -- Конфигурация отвечает не всегда: вне кластера её нет вовсе,
    -- и действие должно отказать, а не уронить панель.
    armed({ uri = '127.0.0.1:3301', broken = true })

    local calls = dialing.new({ login = 'maintenance' })
    local connection, reason = calls.connection('storage-001-a')

    t.assert_equals(connection, nil)
    t.assert_str_contains(reason, 'конфигурация недоступна')
end

g.test_a_node_that_does_not_answer_is_a_refusal_too = function()
    armed({ uri = '127.0.0.1:3301', unreachable = true })

    local calls = dialing.new({ login = 'maintenance' })
    local connection, reason = calls.connection('storage-001-a')

    t.assert_equals(connection, nil)
    t.assert_str_contains(reason, 'связи нет')
end

g.test_closing_lets_go_of_everything_opened = function()
    armed({ uri = '127.0.0.1:3301' })

    local calls = dialing.new({ login = 'maintenance' })

    calls.connection('storage-001-a')
    calls.connection('storage-001-b')
    calls.close()

    t.assert_equals(seen.closed, 2)

    -- Второе закрытие ничего не трогает: закрывать уже нечего.
    calls.close()

    t.assert_equals(seen.closed, 2)
end

g.test_the_real_externals_take_the_pool_and_the_client = function()
    -- Умолчания внешних зависимостей: адрес соседа знает пул диагностики,
    -- а зовёт узел обычный клиент iproto.
    dialing._set_source(nil)

    t.assert_is(dialing.pool(), require('tnt.cluster.pool'))
    t.assert_is(dialing.net_box(), require('net.box'))
end
