--- Обработчики API панели: разобранный запрос на входе, ответ роутера
--- на выходе.
---
--- Источники приходят аргументом при сборке, и обработчики ничего
--- не делают сами: они спрашивают диагностику и просят действия
--- у того, кто их умеет. Поэтому проверяются они без сервера и без
--- кластера — двойником источника.
---
--- Код ответа здесь настоящий: 401 — не вошли, 403 — нет права, 404 —
--- нет такого, 409 — состояние кластера не позволяет, 502 — узлы
--- не ответили. Панель смотрит на код, а не разбирает текст. Наружу
--- не уходит ни стек, ни внутреннее представление ошибки: только код
--- и сообщение, которое можно показать человеку.
---
--- Права обработчики не проверяют: способность называет маршрут слоем
--- `can` (`tnt.admin.app.http.middleware.can`), и до обработчика доходит
--- только тот, кому она выдана. Кому что можно, записано там одним
--- списком, а не условием в каждом обработчике.
---
--- Снимок кластера берётся один раз на запрос и передаётся вниз: иначе
--- страница обзора, которой нужны и узлы, и находки, и подсказки,
--- устроит три обхода кластера подряд. Собирает его служба обзора
--- (`tnt.admin.app.services.overview`) — та же, что кладёт обзор в канал.
---
--- Тело запроса проверяет его форма (`tnt.admin.app.data.requests`),
--- а представление кластера уходит выдачей своей формы
--- (`tnt.admin.app.data.cluster`): из тех же форм собрано описание API,
--- и поле, которого форма не знает, клиенту не уходит вовсе, а не
--- расходится с описанием молча.

local json = require('json')

local router = require('tnt.router')

local model = require('tnt.admin.app.domain.cluster')
local views = require('tnt.admin.app.data.cluster')
local requests = require('tnt.admin.app.data.requests')
local refusals = require('tnt.admin.app.exceptions.refusal')
local overview = require('tnt.admin.app.services.overview')

--- Ответ об отказе по объявленному имени (`tnt.admin.app.exceptions.refusal`).
local refuse = refusals.refuse

local Module = {}

--- Чем подписывается выкладка метрик.
---
--- Не JSON: сборщик читает текст построчно и ничего другого не понимает.
--- Версия формата объявляется в типе содержимого — по ней сборщик решает,
--- как разбирать, и молчание здесь толкуется как «самый старый».
Module.METRICS_TYPE = 'text/plain; version=0.0.4; charset=utf-8'

--- Коды отказа ворот и то, что они значат для оператора.
---
--- Один общий код на три случая приучает жать кнопку, пока не пройдёт,
--- а случаи разные. «Состояние изменилось» значит «посмотрите заново» —
--- это конфликт с тем, что произошло на кластере, и код 409. «Не выполнено
--- требование» — тот же конфликт: сначала сделайте вот это. А «нет
--- подтверждения» — единственный случай, когда от оператора ждут
--- дополнительного шага, и для него есть отдельный код 428.
---
--- Сам статус записан не здесь, а у отказа в `REFUSALS` (`tnt.admin.app.exceptions.refusal`),
--- как у любого другого отказа панели: таблица говорит только, каким
--- отказом панель отвечает на каждый код ворот. Незнакомый код — общий отказ
--- с кодом 400.
local GATE_REFUSAL = {
    STALE_FINGERPRINT = 'stale_fingerprint',
    PRECONDITION_FAILED = 'precondition_failed',
    CONFIRMATION_REQUIRED = 'confirmation_required',
}

--- Раскатка кончилась, не дойдя до конца: это конфликт с тем, что
--- происходит на кластере, а не ошибка запроса.
---
--- Фазы названы в самом механизме, и различать их важно: на сверке
--- и проверке не записано ничего, на записи — уже записано, а на схождении
--- правка доехала не до всех, и чинится это перечитыванием на отставших,
--- а не повтором раскатки.
---
--- Статус, как и у ворот, записан у отказа в `REFUSALS`
--- (`tnt.admin.app.exceptions.refusal`). Незнакомая фаза — общий отказ «правка
--- не раскатана» с кодом 400.
local ROLLOUT_REFUSAL = {
    topology = 'rollout_unfinished',
    prepare = 'rollout_unfinished',
    commit = 'rollout_unfinished',
    converge = 'rollout_unfinished',
}

--- Разбирает тело запроса.
---@param request table
---@return table|nil body Пусто — тело есть, но это не запись
local function body_of(request)
    if request.body == nil or request.body == '' then
        -- Запрос без тела — это не ошибка разбора: полей в нём просто нет,
        -- и отказать за них обязан тот, кому они нужны.
        return {}
    end

    local parsed, decoded = pcall(json.decode, request.body)

    if not parsed or type(decoded) ~= 'table' then
        return nil
    end

    return decoded
end

--- Ответ об отказе ворот: с кодом, оценкой и тем, что именно не сошлось.
---
--- Собирается каталогом, как любой отказ панели: тело, сложенное здесь
--- руками, было бы вторым описанием формы отказа и разошлось бы с видом
--- при первой же правке. `code` в теле — код ворот, а не код каталога:
--- по нему панель узнаёт, какого шага ждут от оператора, а код каталога
--- вид не показывает вовсе. Оценка уходит вместе с отказом намеренно —
--- оператор должен увидеть, что изменилось и какое слово теперь
--- ожидается, а не гадать, почему кнопка не сработала.
---@param refusal table
---@param assessment table|nil
---@return table
local function gate_refusal(refusal, assessment)
    return refuse(GATE_REFUSAL[refusal.code] or 'gate_refused', {
        reason = refusal.message,
        details = { code = refusal.code },
        attached = { assessment = assessment },
    })
end

--- Ответ о незаконченной раскатке: код по фазе и отчёт целиком.
---
--- Собирается каталогом по той же причине, что и отказ ворот. Отчёт
--- уходит рядом с отказом целиком: по нему видно, какие узлы правку
--- приняли, а какие отстали, и чинить отставших без него нечем.
---@param result table
---@return table
local function rollout_conflict(result)
    return refuse(ROLLOUT_REFUSAL[result.phase] or 'rollout_failed', {
        reason = result.err,
        details = { phase = result.phase },
        attached = { rollout = result },
    })
end

---@class TntAdminHandlers
---@field cluster fun(): table
---@field issues fun(): table
---@field suggestions fun(): table
---@field overview fun(): table
---@field capabilities fun(): table
---@field assess fun(request: table): table
---@field act fun(request: table): table
---@field show_config fun(): table
---@field apply_config fun(request: table): table
---@field login fun(request: table): table
---@field metrics fun(request: table): table

--- Собирает обработчики над источниками.
---@param source TntAdminSource
---@return TntAdminHandlers
function Module.new(source)
    local handlers = {}

    --- Разбирает запрос о действии: тело и аргумент.
    ---
    --- Оценка и само действие спрашивают одно и то же и отказывают одинаково:
    --- разница между ними начинается после разбора.
    ---@param request table
    ---@return table|nil body
    ---@return table|nil refusal Готовый ответ об отказе
    local function action_of(request)
        local raw = body_of(request)

        if raw == nil then
            return nil, refuse('bad_body')
        end

        local body, wrong = requests.ActionRequest.from(raw)

        if body == nil then
            return nil, refuse('bad_action', { details = { fields = wrong } })
        end

        return body
    end

    --- Узлы кластера со сводкой по репликасетам.
    ---@return table
    function handlers.cluster()
        return router.json(views.Cluster.to_table(overview.collect(source).cluster))
    end

    --- Находки диагностики.
    ---@return table
    function handlers.issues()
        return router.json(views.Issues.to_table({ issues = overview.collect(source).issues }))
    end

    --- Подсказки оператору.
    ---@return table
    function handlers.suggestions()
        return router.json(views.Suggestions.to_table({ suggestions = overview.collect(source).suggestions }))
    end

    --- Всё сразу и одним обходом: страница обзора спрашивает именно это.
    ---@return table
    function handlers.overview()
        return router.json(overview.of(source))
    end

    --- Что умеет кластер под панелью.
    ---@return table
    function handlers.capabilities()
        local capabilities = source.capabilities ~= nil and source.capabilities() or nil

        return router.json(views.Capabilities.to_table(model.capabilities(capabilities --[[@as TntAdminCapabilities]])))
    end

    --- Оценка действия до того, как что-то произошло.
    ---
    --- Оценка — это чтение: она ничего не меняет и ничего не подтверждает.
    --- Но право на неё то же, что на действие, — `cluster.change` на маршруте:
    --- в ней написано, что именно случится с кластером, и тому, кто менять
    --- его не может, показывать её незачем.
    ---@param request table
    ---@return table
    function handlers.assess(request)
        local body, refusal = action_of(request)

        if body == nil then
            return refusal --[[@as table]]
        end

        if source.assess == nil then
            return refuse('assess_disabled')
        end

        local assessment, reason = source.assess(body.action, body.targets, request.identity)

        if assessment == nil then
            return refuse('assess_failed', { reason = reason })
        end

        return router.json(assessment)
    end

    --- Выполняет действие на узлах.
    ---@param request table
    ---@return table
    function handlers.act(request)
        local body, refusal = action_of(request)

        if body == nil then
            return refusal --[[@as table]]
        end

        if source.act == nil then
            return refuse('act_disabled')
        end

        -- Личность передаётся действию третьим аргументом: решение оператора,
        -- записанное без имени, через неделю невозможно объяснить — и это
        -- ровно тот случай, когда «потом разберёмся» не работает.
        --
        -- Четвёртым идёт подтверждение: отпечаток состояния, по которому
        -- оператор смотрел оценку, признание последствий и слово. Разбирать
        -- их панель не умеет и не должна — она передаёт их тому, у кого
        -- стоят ворота.
        local outcome, reason = source.act(body.action, body.targets, request.identity, {
            fingerprint = body.fingerprint,
            acknowledge = body.acknowledge,
            confirm_token = body.confirm_token,

            -- Ответы на требования оценки: «смену лидера приостановил»,
            -- «снимок снял». Это утверждения оператора о том, что он сделал,
            -- и проверить их некому — но ответить за них он должен явно,
            -- а не молчанием.
            answers = body.answers,

            -- Ключ запроса: один на нажатие кнопки, а не на попытку. Браузер,
            -- не дождавшийся ответа, шлёт тот же запрос заново, и узел обязан
            -- узнать в нём повтор, а не второе нажатие.
            key = body.key,
        })

        if outcome == nil then
            return refuse('act_failed', { reason = reason })
        end

        -- Ворота отказали: это не ошибка запроса, а разговор с оператором,
        -- и коды у него свои.
        if outcome.refused ~= nil then
            return gate_refusal(outcome.refused, outcome.assessment)
        end

        -- Частичный успех — обычное дело: код говорит об этом отдельно,
        -- а карта по узлам всегда на месте.
        return router.json(outcome, outcome.status == 'complete' and 200 or 207)
    end

    --- Показывает действующую конфигурацию кластера.
    ---
    --- Наблюдателю её не показывают вовсе — право `cluster.config.read`
    --- на маршруте: в ней состав кластера, учётные записи и адреса. Секреты
    --- из неё убирает тот, кто её отдаёт: панель знает, что показывает,
    --- а слой HTTP — только то, что это текст.
    ---@return table
    function handlers.show_config()
        if source.config == nil then
            return refuse('config_disabled')
        end

        local config, reason = source.config()

        if config == nil then
            return refuse('config_failed', { reason = reason })
        end

        return router.json(config)
    end

    --- Раскатывает правку конфигурации по кластеру.
    ---@param request table
    ---@return table
    function handlers.apply_config(request)
        local raw = body_of(request)

        if raw == nil then
            return refuse('bad_body')
        end

        local body, wrong = requests.RolloutRequest.from(raw)

        if body == nil then
            return refuse('bad_rollout', { details = { fields = wrong } })
        end

        if source.apply_config == nil then
            return refuse('rollout_disabled')
        end

        local result, reason = source.apply_config(body.text, body.removing or {}, request.identity)

        if result == nil then
            return refuse('rollout_failed', { reason = reason })
        end

        if result.err ~= nil then
            return rollout_conflict(result)
        end

        return router.json(result)
    end

    --- Пускает по имени и паролю.
    ---@param request table
    ---@return table
    function handlers.login(request)
        local raw = body_of(request)

        if raw == nil then
            return refuse('bad_body')
        end

        -- Без имени или пароля проверять нечего, и отказ называет поля:
        -- слово у него то же, что у тела не JSON, а какие поля не так,
        -- видно по разбору. Значение пароля отказ не показывает.
        local credentials, wrong = requests.LoginRequest.from(raw)

        if credentials == nil then
            return refuse('bad_body', { details = { fields = wrong } })
        end

        if source.authenticate == nil then
            return refuse('login_disabled')
        end

        local identity, reason, retry_after = source.authenticate(credentials.username, credentials.password, request)

        if identity == nil and retry_after ~= nil then
            -- Подбор пароля: отвечаем сроком, а не отказом. Отказ без срока
            -- читается как поломка, и по нему стучат ещё чаще.
            return refuse('login_throttled', {
                reason = reason,
                headers = { ['retry-after'] = tostring(retry_after) },
            })
        end

        if identity == nil then
            -- Причина одна на оба случая: по разным ответам подбирают имена
            -- пользователей.
            return refuse('login_failed', { reason = reason })
        end

        return router.json(identity)
    end

    --- Отдаёт метрики тому, кому это разрешено.
    ---
    --- Кому именно — решает не панель, а приложение: у сборщика нет ни cookie,
    --- ни сессии, и своя мерка доступа. Здесь только вид ответа и коды: текст
    --- при удаче, 401 при отказе, 501 там, где выкладку не включали вовсе.
    ---@param request table
    ---@return table
    function handlers.metrics(request)
        if source.metrics == nil then
            return refuse('metrics_disabled')
        end

        local text, reason = source.metrics(request)

        if text == nil then
            return refuse('metrics_closed', { reason = reason })
        end

        return router.text(text, 200, { ['content-type'] = Module.METRICS_TYPE })
    end

    return handlers
end

return Module
