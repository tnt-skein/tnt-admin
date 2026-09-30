--- Провайдер панели: что лежит в контейнере и откуда берётся.
---
--- Источники собираются по настройке роли: пакет, установленный рядом,
--- даёт снимок кластера, находки, подсказки и журнал аудита, а выключенный
--- настройкой источник панель считает отсутствующим. Что взято, провайдер
--- называет в журнале при каждом применении: умолчание не должно быть
--- молчаливым.
---
--- Обработчики и слой опознавания собираются здесь же, над теми же
--- источниками, а рядом — ворота прав панели: маршрутам остаётся взять
--- их по имени.

local acting = require('tnt.admin.app.services.acting')
local handlers = require('tnt.admin.app.http.handlers.panel')
local authorize = require('tnt.admin.app.http.middleware.authorize')
local can = require('tnt.admin.app.http.middleware.can')
local settings_of = require('tnt.admin.app.services.settings')
local sources = require('tnt.admin.app.services.sources')
local watch = require('tnt.admin.app.services.watch')

local bundle = require('tnt.admin.public.bundle')

--- Имена в контейнере: источники, обработчики, слой опознавания и ворота.
---
--- С приставкой `admin_`: контейнер у панели свой, но читает его и тот,
--- кто смотрит на приложение рядом, — и `source` без приставки там
--- значило бы что угодно.
local SOURCE = 'admin_source'
local HANDLERS = 'admin_handlers'
local GUARD = 'admin_guard'
local GATE = 'admin_gate'

--- Имена найденного по алфавиту: строка для журнала.
---@param available table<string, boolean>
---@return string
local function listed(available)
    local names = {}

    for field, found in pairs(available) do
        -- Смотреть надо на значение, а не на ключ: запись «источника
        -- нет» — это тоже запись, и перечень по одним ключам назвал бы
        -- недостающее найденным.
        if found then
            table.insert(names, field)
        end
    end

    table.sort(names)

    return #names > 0 and table.concat(names, ', ') or 'ничего'
end

--- Что панель раздаёт и чем отвечает, собранное по настройке.
---@param settings table Раздел настроек роли
---@return table collected Источники для панели
---@return table<string, boolean> available Что из них нашлось
local function collected_for(settings)
    local collected, available = sources.collect({ disabled = settings_of.disabled(settings) })

    -- Файлы панели раздаёт она сама: отдельного веб-сервера для статики
    -- нет, и расхождению версий панели и узла взяться неоткуда.
    collected.panel = bundle

    -- Действия над кластером: панель зовёт то, что узлы опубликовали,
    -- и показывает только то, чьи пакеты установлены рядом.
    local actions = acting.build(settings.actions)

    if actions ~= nil then
        collected.capabilities = actions.capabilities
        collected.assess = actions.assess
        collected.act = actions.act
        available.actions = true
    else
        collected.capabilities = function()
            return {
                failover = false,
                config_rollout = false,
                authenticated = false,
                actions = {},
            }
        end
    end

    return collected, available
end

return {
    ---@param app TntDiContainer
    ---@param config TntKernelConfig
    register = function(app, config)
        local collected, available = collected_for(config.role)

        app:value(SOURCE, collected)
        app:value(GUARD, authorize.new(collected))
        app:value(GATE, can.gate())
        app:value(HANDLERS, handlers.new(collected))

        local log = app:get('log')

        log.info('панель питается: {sources}', { sources = listed(available) })

        -- Снимок кластера кто-то должен снимать: обычно это приложение,
        -- а на узле, где панель стоит одна, — она сама, если ей дали
        -- учётку наблюдателя.
        local started = watch.start(config.role.watch)

        if started ~= nil then
            log.info(started)
        end
    end,
}
