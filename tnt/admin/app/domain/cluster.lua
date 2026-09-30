--- Что панель показывает: снимок кластера в виде, пригодном для чтения.
---
--- Модуль чистый: на входе снимок диагностики, находки и подсказки, на
--- выходе таблицы, которые остаётся сериализовать в JSON. Ни сети, ни box —
--- поэтому ответ панели проверяется без кластера.
---
--- Две вещи в составе полей важнее остальных, и обе подсказаны
--- эксплуатацией.
---
--- Первая: назначенный лидер и фактический писатель — разные поля.
--- Расхождение между ними само по себе говорит больше, чем любая находка:
--- назначение записано, а узел его ещё не применил или уже потерял.
---
--- Вторая: панель не должна знать, что умеет кластер. Умеет ли он двигать
--- лидерство извне, есть ли координатор, ведутся ли выборы — всё это
--- объявляется признаками, и панель рисует то, что объявлено. Иначе одна
--- панель не годится для разных кластеров, а она у нас одна.

local Module = {}

--- Версия представления. Меняется, когда меняется смысл полей: панель
--- старой версии не должна молча показывать не то.
Module.VERSION = 1

--- Что известно об узле.
---
--- Вывод из эксплуатации — отдельный признак, а не ещё одно состояние:
--- выведенный узел обычно продолжает отвечать, и подменять им `status`
--- значило бы прятать то, что с узлом на самом деле.
---@param name string
---@param entry table
---@param retired table|nil Запись о выводе, если узел выведен
---@return table
local function server_of(name, entry, retired)
    local memory = entry.memory or {}
    local config = entry.config or {}

    return {
        name = name,
        replicaset = entry.replicaset_name,
        uri = entry.advertise ~= nil and entry.advertise.uri or nil,
        status = entry.reachable and (entry.status or 'unknown') or 'unreachable',
        reachable = entry.reachable == true,
        -- Писателем узел считается по факту, а не по назначению: ими
        -- и различаются «назначен» и «пишет».
        writable = entry.reachable == true and entry.ro == false,
        message = entry.failure ~= nil and entry.failure.message or nil,
        last_seen = entry.last_seen,
        uptime = entry.uptime,
        version = entry.version,
        lsn = entry.lsn,
        clock = entry.clock,
        memory = {
            arena_ratio = memory.arena_ratio,
            items_ratio = memory.items_ratio,
            quota_ratio = memory.quota_ratio,
        },
        config = {
            status = config.status,
            fingerprint = config.fingerprint,
        },
        lifecycle = (entry.extensions or {}).lifecycle,
        retired = retired,
    }
end

--- Что известно о репликасете.
---@param name string
---@param replicaset table
---@param appointments table<string, string>|nil Назначения координатора
---@return table
local function replicaset_of(name, replicaset, appointments)
    local appointed = (appointments or {})[name]
    local writers = replicaset.leaders or {}

    return {
        name = name,
        servers = replicaset.instances,
        -- Кого назначили и кто на самом деле пишет: расхождение между
        -- ними само по себе говорит больше, чем любая находка.
        leader = appointed,
        active_leader = writers[1],
        writers = writers,
        healthy = #writers == 1,
    }
end

--- Узлы по порядку.
---@param entries table<string, table>
---@return string[]
local function names_of(entries)
    local names = {}

    for name in pairs(entries or {}) do
        table.insert(names, name)
    end

    table.sort(names)

    return names
end

---@class TntAdminView
---@field version integer Версия представления
---@field generation integer Номер обхода
---@field taken_at number Когда снят снимок
---@field self_name string|nil Имя узла, отвечающего панели
---@field servers table[] Узлы
---@field replicasets table[] Репликасеты
---@field summary table Сводка

--- Собирает представление кластера.
---@param snapshot table|nil Снимок диагностики
---@param opts { appointments: table<string, string>|nil }|nil
---@return TntAdminView
function Module.cluster(snapshot, opts)
    opts = opts or {}
    snapshot = snapshot or {}

    local servers = {}
    local unreachable = 0
    local retired = snapshot.disabled or {}
    local retired_count = 0

    for _, name in ipairs(names_of(snapshot.instances)) do
        local server = server_of(name, snapshot.instances[name], retired[name])

        if not server.reachable then
            unreachable = unreachable + 1
        end

        -- Выведенные считаются отдельно, а не вычитаются из недоступных:
        -- недоступность — про связность, вывод — про намерение человека,
        -- и узел вправе быть и тем, и другим сразу.
        if server.retired ~= nil then
            retired_count = retired_count + 1
        end

        table.insert(servers, server)
    end

    local replicasets = {}

    for _, name in ipairs(names_of(snapshot.replicasets)) do
        table.insert(replicasets, replicaset_of(name, snapshot.replicasets[name], opts.appointments))
    end

    return {
        version = Module.VERSION,
        generation = snapshot.generation or 0,
        taken_at = snapshot.taken_at,
        self_name = snapshot.self_name,
        servers = servers,
        replicasets = replicasets,
        summary = {
            total = #servers,
            unreachable = unreachable,
            retired = retired_count,
            replicasets = #replicasets,
        },
        -- Когда список выведенных читался удачно в последний раз. Единственный
        -- способ отличить «никого не выводили» от «хранилище молчит, показываем
        -- вчерашнее»: сам список этой разницы не несёт.
        retired_read_at = snapshot.disabled_read_at,
    }
end

--- Приводит находки к виду, пригодному для показа.
---@param issues table[]|nil
---@return table[]
function Module.issues(issues)
    local shown = {}

    for _, issue in ipairs(issues or {}) do
        table.insert(shown, {
            id = issue.id,
            rule = issue.rule,
            level = issue.severity,
            scope = issue.scope,
            server = issue.instance,
            replicaset = issue.replicaset,
            message = issue.message,
        })
    end

    return shown
end

--- Приводит подсказки к виду, пригодному для показа.
---@param suggestions table[]|nil
---@return table[]
function Module.suggestions(suggestions)
    local shown = {}

    for _, suggestion in ipairs(suggestions or {}) do
        table.insert(shown, {
            action = suggestion.action,
            targets = suggestion.targets,
            message = suggestion.message,
            reasons = suggestion.reasons,
        })
    end

    return shown
end

---@class TntAdminCapabilities
---@field failover boolean Есть ли внешний координатор смены лидера
---@field config_rollout boolean Умеет ли кластер раскатывать конфигурацию
---@field actions string[] Какие действия панель вправе предлагать
---@field authenticated boolean Включён ли вход по паролю

--- Что умеет этот кластер.
---
--- Панель спрашивает, а не догадывается: она одна на все кластеры, и в
--- одном есть координатор, в другом выборы ядра, в третьем ни того,
--- ни другого. Зашитые предположения об этом делают панель годной ровно
--- для одного развёртывания.
---@param opts TntAdminCapabilities|nil
---@return table
function Module.capabilities(opts)
    ---@type TntAdminCapabilities
    local declared = opts or { failover = false, config_rollout = false, authenticated = false, actions = {} }

    return {
        version = Module.VERSION,
        failover = declared.failover == true,
        config_rollout = declared.config_rollout == true,
        authenticated = declared.authenticated == true,
        actions = declared.actions or {},
    }
end

return Module
