--- Действия над кластером: панель зовёт то, что узлы опубликовали.
---
--- Панель ничего не делает сама. Тело каждого действия живёт в своём
--- пакете и публикуется на узле глобальной функцией, право на вызов
--- которой выдаёт конфигурация поимённо (`tnt.ops`, `tnt.sharding`).
--- Здесь — только карта: как действие зовётся в панели, какую функцию
--- звать на узле, насколько оно опасно и что о нём сказать оператору.
---
--- Что доступно, решает узел, а не панель: действие попадает в перечень
--- только тогда, когда пакет с его телом установлен рядом. Кнопка,
--- которая заведомо ответит отказом, хуже её отсутствия.
---
--- Опасное проходит через ворота (`tnt.recovery.gate`): оператор сперва
--- смотрит оценку — что именно случится, — а потом подтверждает её
--- отпечатком состояния и словом. Отпечаток считается по тому же снимку,
--- который оператор видел: кластер, изменившийся между оценкой
--- и нажатием, — это другой кластер, и подтверждение к нему не относится.

local external = require('tnt.external')

local dialing = require('tnt.admin.app.services.dialing')
local packages = require('tnt.admin.app.support.packages')

local Module = {}

--- Сколько ждать ответ узла на действие, секунд.
---
--- Больше срока обхода: обход спрашивает узел о нём самом, а действие
--- узел выполняет — перечитывание конфигурации доходит до диска.
Module.TIMEOUT = 10

--- Пакеты, из которых берутся действия.
---
--- Каждый — отдельной функцией: так проверка умолчаний остаётся
--- проверкой, а не разбором внутренностей внешней зависимости.
---@return table|nil
function Module.cluster()
    return packages.of('tnt.cluster')
end

--- Пакет действий над узлами.
---@return table|nil
function Module.ops()
    return packages.of('tnt.ops.actions')
end

--- Пакет действий шардирования.
---@return table|nil
function Module.sharding()
    return packages.of('tnt.sharding.actions')
end

--- Оценка риска действия.
---@return table|nil
function Module.risk()
    return packages.of('tnt.recovery.risk')
end

--- Ворота: пускать ли опасное.
---@return table|nil
function Module.gate()
    return packages.of('tnt.recovery.gate')
end

--- Средства снаружи: пакеты, из которых берутся действия.
---
--- Внешней зависимостью, потому что проверки идут и с установленными
--- пакетами, и без них: на машине, где стоит то одно, то другое, это
--- не проверить.
local source = external.install(Module, {
    cluster = Module.cluster,
    ops = Module.ops,
    sharding = Module.sharding,
    risk = Module.risk,
    gate = Module.gate,
})

--- Что панель умеет просить у узлов.
---
--- Риск объявлен здесь, а не в пакете действия: он зависит от того, что
--- действие делает с живым кластером, а не от того, как оно устроено
--- внутри. Безопасное идёт сразу, осторожное — через ворота, которые
--- проверяют требования и свежесть картины.
---
--- Опасного — того, после чего пропадают подтверждённые записи, — панель
--- пока не предлагает вовсе: такому нужно слово подтверждения, и вместе
--- с ним придёт кнопка, которая его спрашивает.
---@return table<string, table>
local function catalog()
    local ops = source().ops()
    local sharding = source().sharding()
    local known = {}

    if ops ~= nil then
        known.reload_config = {
            func = ops.RELOAD_FUNCTION,
            risk = 'safe',
            summary = 'узел перечитает конфигурацию из своего источника',
            effects = {
                'роли применяются заново',
                'соединения к соседям не рвутся',
            },
        }

        known.restart_replication = {
            func = ops.RESTART_REPLICATION_FUNCTION,
            risk = 'caution',
            summary = 'узел переподключится к соседям по репликасету',
            effects = { 'репликация прервётся на время переподключения' },
        }
    end

    if sharding ~= nil then
        known.sharding_bootstrap = {
            func = sharding.FUNCTIONS.bootstrap,
            risk = 'caution',
            summary = 'бакеты будут разложены по хранилищам',
            effects = {
                'разметка делается один раз на кластер',
                'повторный вызов на размеченном кластере ничего не меняет',
            },
        }

        known.sharding_rebalancer = {
            func = sharding.FUNCTIONS.rebalancer,
            risk = 'caution',
            summary = 'перебалансировка бакетов будет включена или выключена',
            effects = {
                'включённая перебалансировка двигает бакеты между хранилищами',
            },
        }
    end

    return known
end

--- Оценка действия: что случится и чего для этого не хватает.
---@param known table Запись каталога
---@param action string
---@param targets string[]
---@return table|nil assessment
---@return string|nil err
local function assessed(known, action, targets)
    local risk = source().risk()
    local cluster = source().cluster()

    if risk == nil then
        return nil, 'оценка действий на этом кластере не включена'
    end

    local snapshot = cluster ~= nil and cluster.current() or nil

    return risk.of({
        action = action,
        risk = known.risk,
        summary = known.summary,
        effects = known.effects,
        -- Отпечаток состояния: по нему ворота отличают подтверждение,
        -- данное по этой картине, от данного по вчерашней.
        fingerprint = snapshot ~= nil and risk.fingerprint(snapshot, targets) or '',
    })
end

---@class TntAdminActing
---@field capabilities fun(): table Что умеет кластер под этой панелью
---@field assess fun(action: string, targets: string[], identity: table): table|nil, string|nil
---@field act fun(action: string, targets: string[], identity: table, confirmation: table|nil): table|nil, string|nil
---@field close fun() Закрывает соединения к узлам

--- Собирает действия панели по тому, что установлено рядом.
---
--- Пусто — значит действий нет вовсе: панель тогда честно отвечает
--- «действия на этом кластере не включены», а кнопок не показывает.
--- Пусто и без учётки: звать действия наблюдателем нельзя — узел
--- откажет «нет права», и кнопка обещала бы то, чего не будет.
---@param settings table|nil Раздел `actions` настроек панели
---@return TntAdminActing|nil
function Module.build(settings)
    local given = settings or {}
    local known = catalog()

    if given.login == nil or next(known) == nil then
        return nil
    end

    local calls = dialing.new(given)
    local acting = {}

    --- Имена действий по алфавиту: панель показывает их списком.
    ---@return string[]
    local function names()
        local listed = {}

        for name in pairs(known) do
            table.insert(listed, name)
        end

        table.sort(listed)

        return listed
    end

    --- Что умеет кластер под этой панелью.
    ---@return table
    function acting.capabilities()
        return {
            failover = false,
            config_rollout = false,
            authenticated = false,
            actions = names(),
        }
    end

    --- Оценка действия до того, как что-то произошло.
    ---@param action string
    ---@param targets string[]
    ---@return table|nil
    ---@return string|nil
    function acting.assess(action, targets)
        local entry = known[action]

        if entry == nil then
            return nil, ('действие %s этому кластеру недоступно'):format(action)
        end

        return assessed(entry, action, targets)
    end

    --- Выполняет действие на названных узлах.
    ---
    --- Ворота стоят до вызова: опасное без свежей оценки и подтверждения
    --- дальше не идёт, а отказ уходит оператору кодом, по которому панель
    --- понимает, чего от него ждут.
    ---@param action string
    ---@param targets string[]
    ---@param _identity table Кто просит: его имя пишет журнал аудита узла
    ---@param confirmation table|nil Отпечаток, признание и слово
    ---@return table|nil
    ---@return string|nil
    function acting.act(action, targets, _identity, confirmation)
        local entry = known[action]

        if entry == nil then
            return nil, ('действие %s этому кластеру недоступно'):format(action)
        end

        local assessment, reason = assessed(entry, action, targets)

        if assessment == nil then
            return nil, reason
        end

        local gate = source().gate()
        local verdict = gate ~= nil and gate.decide(assessment, confirmation) or { allow = true }

        if not verdict.allow then
            return { refused = { code = verdict.code, message = verdict.message }, assessment = assessment }
        end

        local ops = source().ops()

        if ops == nil then
            return nil, 'действия на этом кластере не включены'
        end

        return ops.run({
            action = action,
            targets = targets,
            func = entry.func,
            connection = calls.connection,
            timeout = given.timeout or Module.TIMEOUT,
        })
    end

    --- Закрывает соединения: панель снимают вместе с ними.
    function acting.close()
        calls.close()
    end

    return acting
end

return Module
