--- Связь с узлами для действий: своя учётка, свои соединения.
---
--- Смотреть и менять — разные права, и учётки у них разные: наблюдатель
--- умеет только звать зонд, обслуживание — только те действия, которые
--- ему выдали поимённо. Поэтому действия панель выполняет не через пул
--- диагностики — он открыт под наблюдателем, и узел отказал бы «Execute
--- access denied», — а через свои соединения.
---
---     -- config/admin.lua
---     actions = {
---         login = env('ADMIN_ACTIONS_LOGIN', 'maintenance'),
---         password = env('ADMIN_ACTIONS_PASSWORD'),
---     }
---
--- Соединения открываются по требованию и держатся до смены адреса или
--- поломки: действие на кластере из десятка узлов иначе платило бы
--- установлением связи за каждый узел и каждое нажатие.

local external = require('tnt.external')

local Module = {}

--- Пул диагностики: в нём живёт знание, как достать адрес соседа
--- из конфигурации кластера.
---@return table
function Module.pool()
    return require('tnt.cluster.pool')
end

--- Клиент iproto, которым панель зовёт действия на узлах.
---@return table
function Module.net_box()
    return require('net.box')
end

--- Средства снаружи: пул диагностики и клиент iproto.
---
--- Внешней зависимостью, потому что проверки идут без кластера: адресов
--- соседей вне его нет, а настоящие соединения в них открывать некуда.
local source = external.install(Module, { pool = Module.pool, net_box = Module.net_box })

--- Годно ли соединение для вызова.
---
--- `net.box` держит состояние сам: закрытое или оборванное соединение
--- узнаётся по нему, а не по догадкам о времени.
---@param connection table|nil
---@return boolean
local function usable(connection)
    return connection ~= nil and connection.state ~= 'closed' and connection.state ~= 'error'
end

---@class TntAdminDialing
---@field connection fun(name: string): table|nil, string|nil Соединение с узлом
---@field close fun() Закрывает всё открытое

--- Заводит набор соединений под названной учёткой.
---@param settings table Раздел `actions` настроек панели: login, password
---@return TntAdminDialing
function Module.new(settings)
    ---@type table<string, { connection: table, uri: string }>
    local opened = {}

    local dialing = {}

    --- Соединение с узлом по имени.
    ---
    --- Адрес берётся из конфигурации кластера, а не из снимка: снимок
    --- показывает, каким узел был на последнем обходе, а звать его надо
    --- по тому адресу, который объявлен сейчас.
    ---@param name string
    ---@return table|nil
    ---@return string|nil
    function dialing.connection(name)
        local uri, err = source().pool().peer_uri(name, settings)

        if uri == nil then
            return nil, err
        end

        local entry = opened[name]

        if entry ~= nil and usable(entry.connection) and entry.uri == uri.uri then
            return entry.connection
        end

        if entry ~= nil then
            pcall(entry.connection.close, entry.connection)
        end

        local net_box = source().net_box()
        local connected, connection = pcall(net_box.connect, uri)

        if not connected then
            opened[name] = nil

            return nil, tostring(connection)
        end

        ---@cast connection table
        opened[name] = { connection = connection, uri = uri.uri }

        return connection
    end

    --- Закрывает открытое: панель снимают вместе с её соединениями.
    function dialing.close()
        for name, entry in pairs(opened) do
            pcall(entry.connection.close, entry.connection)

            opened[name] = nil
        end
    end

    return dialing
end

return Module
