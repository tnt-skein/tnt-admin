--- Чем узел питает панель: снимок кластера, находки, подсказки, отбор
--- узлов по конфигурации, журнал аудита, выкладка метрик и вход оператора.
---
--- Панель не знает, что установлено рядом: она спрашивает то, что ей дали,
--- и о недостающем отвечает отказом с понятным кодом. Поэтому набор
--- собирается здесь, по одному источнику на пакет: пакета нет — источника
--- нет, и панель просто не показывает эту часть.
---
--- Пакеты берутся по имени, а не объявлены зависимостями: диагностика,
--- аудит, метрики и вход нужны не каждому развёртыванию, а обязательная
--- зависимость притащила бы их все. Имя ищется один раз на сборку набора.
---
--- Настройка выключает источник, который установлен, но не нужен:
--- выключенный источник панель считает отсутствующим, и кнопка, которая
--- заведомо ответила бы отказом, не появляется вовсе.

local external = require('tnt.external')

local Module = {}

--- Выполнение действия на узлах.
---
--- Третьим аргументом идёт личность оператора, четвёртым — его подтверждение:
--- отпечаток состояния из оценки, признание последствий и слово. Разбирать
--- их панель не умеет и не должна — это дело того, у кого стоят ворота.
---@alias TntAdminAct
---| fun(action: string, targets: string[], identity: table, confirmation: table|nil): table|nil, string|nil

--- Раскатка правки конфигурации по кластеру.
---
--- Второй аргумент — то, что оператор объявил вслух: какие узлы он выводит
--- из состава. Вычеркнуть узел и вывести его — разные вещи, и первое
--- обычно случайность.
---@alias TntAdminApplyConfig
---| fun(text: string, removing: string[], identity: table): table|nil, string|nil

--- Вход по имени и паролю.
---
--- Третьим аргументом идёт сам запрос: по нему приложение узнаёт, откуда
--- пришли, и считает неудачные догадки. Третьим ответом — срок, через
--- который пробовать снова: по нему слой HTTP отличает «неверный пароль»
--- от «слишком много попыток», а это разные коды ответа.
---@alias TntAdminAuthenticate
---| fun(username: string, password: string, request: table): table|nil, string|nil, number|nil

--- Отбор узлов по конфигурации.
---
--- Отбор и узлы — те же, что у `tnt.cluster.filter`: панель переводит в него
--- строку запроса и ничего к нему не дописывает. Отказ — пара, и её слово
--- уходит оператору.
---@alias TntAdminFilter
---| fun(selector: TntClusterSelector): TntClusterInstance[]|nil, string|nil

--- Кто выполняет запрос: личность, которую отдаёт `authorize`.
---
--- Права в ней — только признаки, и выдаёт их приложение: панель не знает,
--- кто у него оператор, а кто аудитор. Чтение журнала аудита — отдельное
--- право `audit`, а не «право менять»: проверять журнал должен уметь тот,
--- кто не может его подделать.
--- Извещение о новом снимке кластера.
---
--- Подписка: панель отдаёт функцию, которую звать на каждый новый снимок,
--- и получает функцию отписки. По извещению толчок обзора
--- (`tnt.admin.app.services.live`) публикует обзор в канал Centrifugo;
--- без него канала нет, и браузер обновляет страницу опросом.
---@alias TntAdminUpdates fun(notify: fun()): fun()

---@class TntAdminIdentity
---@field username string|nil Имя оператора
---@field ["readonly"] boolean|nil Только смотреть: ни действий, ни конфигурации
---@field audit boolean|nil Читать журнал аудита и проверять его цепочку

---@class TntAdminSource
---@field snapshot (fun(): table|nil)|nil Снимок кластера
---@field issues (fun(): table[])|nil Находки диагностики
---@field suggestions (fun(): table[])|nil Подсказки оператору
---@field filter TntAdminFilter|nil Узлы конфигурации по отбору
---@field appointments (fun(): table<string, string>|nil)|nil Назначения координатора
---@field capabilities (fun(): table)|nil Что умеет кластер
---@field authenticate TntAdminAuthenticate|nil Вход по имени и паролю
---@field authorize (fun(request: table): TntAdminIdentity|nil, string|nil)|nil Кто выполняет запрос
---@field act TntAdminAct|nil
---@field assess (fun(action: string, targets: string[], identity: table): table|nil, string|nil)|nil Оценка до действия
---@field config (fun(): table|nil, string|nil)|nil Действующая конфигурация кластера
---@field apply_config TntAdminApplyConfig|nil
---@field metrics (fun(request: table): string|nil, string|nil)|nil Выкладка метрик
---@field audit TntAdminAuditExport|nil Выгрузка журнала аудита кусками
---@field audit_verify TntAdminAuditVerify|nil Проверка цепочки журнала аудита
---@field updates TntAdminUpdates|nil Извещение о новом снимке кластера
---@field panel table<string, string>|nil Файлы панели: имя внутри набора → содержимое

--- Подключает пакет по имени: не установлен — пусто.
---
--- Пустота, а не бросок: пакет, которого нет, — это обычное
--- развёртывание без диагностики или без аудита, а не поломка узла.
---@param name string Имя модуля, например tnt.cluster
---@return any|nil
function Module.load(name)
    local ok, module = pcall(require, name)

    if not ok then
        return nil
    end

    return module
end

--- Наблюдатель события узла: `box.watch`.
---@param key string Имя события
---@param callback fun(key: string, value: any)
---@return { unregister: fun(self: any) }
function Module.watch(key, callback)
    return box.watch(key, callback)
end

--- Средства снаружи: подключение модуля по имени и наблюдатель событий.
---
--- Внешней зависимостью, потому что проверки обязаны видеть и набор
--- с установленными пакетами, и набор без них — на машине, где стоит то
--- одно, то другое, это не проверить. Наблюдатель — по той же причине,
--- что всякое средство `box`: проверка ведёт событие сама.
local source = external.install(Module, { load = Module.load, watch = Module.watch })

--- Извещение о новом снимке по событию диагностики.
---
--- Каждый обход диагностика объявляет событием узла (`tnt.cluster.EVENT`):
--- подписка на него — наблюдатель, а отписка его снимает. Пакет без
--- события — отставший от панели — извещения не даёт, и толчка у панели
--- нет, а не бросок на первом подключении.
---@param cluster table Пакет диагностики
---@return TntAdminUpdates|nil
local function updates_of(cluster)
    local event = cluster.EVENT

    if type(event) ~= 'string' then
        return nil
    end

    return function(notify)
        local watcher = source().watch(event, function()
            notify()
        end)

        return function()
            watcher:unregister()
        end
    end
end

--- Откуда берутся источники: поле панели, модуль и как взять из него
--- действие.
---
--- Таблицей, а не пятнадцатью ветками: набор читается сверху вниз,
--- и добавить источник — это строка, а не ещё одно место, где можно
--- забыть про выключение.
---@type { field: string, module: string, take: fun(module: any): any }[]
local PROVIDERS = {
    {
        field = 'snapshot',
        module = 'tnt.cluster',
        take = function(cluster)
            return cluster.current
        end,
    },
    {
        field = 'issues',
        module = 'tnt.cluster',
        take = function(cluster)
            return cluster.findings
        end,
    },
    {
        field = 'suggestions',
        module = 'tnt.cluster',
        take = function(cluster)
            return cluster.suggestions
        end,
    },
    {
        field = 'filter',
        module = 'tnt.cluster',
        take = function(cluster)
            return cluster.filter
        end,
    },
    {
        field = 'updates',
        module = 'tnt.cluster',
        take = updates_of,
    },
    {
        field = 'audit',
        module = 'tnt.audit.stream',
        take = function(stream)
            return stream.open
        end,
    },
    {
        field = 'audit_verify',
        module = 'tnt.audit.verify',
        take = function(verify)
            return verify.run
        end,
    },
}

--- Собирает набор источников для панели.
---
--- Выключенные поля не спрашиваются вовсе: пакет может быть установлен
--- ради соседа, и молчаливо показывать его данные панель не должна.
---@param opts { disabled: table<string, boolean>|nil }|nil
---@return table sources Поля, которые панель получит
---@return table<string, boolean> available Что нашлось: поле → да
function Module.collect(opts)
    local settings = opts or {}
    local disabled = settings.disabled or {}
    local load = source().load

    local sources, available = {}, {}
    local modules = {}

    for _, provider in ipairs(PROVIDERS) do
        if not disabled[provider.field] then
            local module = modules[provider.module]

            if module == nil then
                module = load(provider.module)
                modules[provider.module] = module or false
            end

            local action = module and provider.take(module) or nil

            if type(action) == 'function' then
                sources[provider.field] = action
                available[provider.field] = true
            end
        end
    end

    return sources, available
end

return Module
