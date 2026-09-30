--- Страницы панели: их рисует узел, а не браузер.
---
--- Страницу собирает шаблонизатор `tnt-template`, как и всякую другую
--- страницу приложения: разметка лежит рядом с пакетом, данные приходят
--- из тех же источников, что и в ответы API. Поэтому панель работает
--- и без сценариев: отбор — это адрес, действие — обычная форма.
---
--- Сценарий панели остаётся, но у него ровно две заботы: обновлять
--- страницу самой и помнить выбранную тему. Всё остальное — разметка,
--- пришедшая с узла.
---
--- Данные и вид разделены так же, как в API: `tnt.admin.app.domain.cluster` делает
--- из снимка кластера таблицы, а страница их только раскладывает.
--- Одни и те же слова на странице и в ответе API берутся из одного
--- места (`tnt.admin.app.support.format`), и разойтись им негде.

local json = require('json')
local validate = require('tnt.validate')

--- Отказ словом, без места в коде: причина уходит в журнал узла.
local fail = require('tnt.must.fail').raise

local model = require('tnt.admin.app.domain.cluster')

local format = require('tnt.admin.app.support.format')

local Module = {}

--- Разделы панели: путь, имя в меню и кто собирает данные.
---
--- Меню собирается отсюда же: раздел, добавленный в этот список,
--- появляется в меню сам, и забыть про него нельзя. Признак `stream` —
--- страница идёт клиенту потоком, по мере рисования: её длину задаёт
--- не панель, а то, сколько накопилось в источнике.
Module.SECTIONS = {
    { path = '/', name = 'overview', title = 'Обзор' },
    { path = '/cluster', name = 'cluster', title = 'Узлы' },
    { path = '/issues', name = 'issues', title = 'Находки' },
    { path = '/config', name = 'config', title = 'Конфигурация' },
    { path = '/audit', name = 'audit', title = 'Журнал', stream = true },
}

--- Сколько записей журнала на одной странице.
---
--- Поток бережёт память узла: в ней лежит кусок выгрузки, а не журнал.
--- Но поток без предела всё равно тянул бы журнал целиком одним
--- ответом, а браузер держал бы его одним документом. Тысяча строк —
--- несколько сотен килобайт разметки; дальше — ссылкой на следующую
--- страницу.
Module.AUDIT_LIMIT = 1000

--- Больше номера записи страница не принимает.
---
--- Предел тот же, что у выгрузки API, и обоснование там же
--- (`tnt.admin.app.http.handlers.audit`): страница и выгрузка читают
--- один журнал, и отрезок, который одна принимает, а другая
--- отвергает, выглядел бы поломкой. Что пределы не разошлись,
--- проверяют проверки страниц: на пределе страница рисует журнал,
--- за пределом — отказ теми же словами, что у API.
local LARGEST_ID = 10 ^ 14 - 1

--- Номер записи в строке запроса.
local RECORD_ID = validate.integer({ min = 1, max = LARGEST_ID, optional = true })

--- Поля отрезка журнала — в том порядке, в каком о них говорит отказ.
local RANGE_FIELDS = { 'from_id', 'to_id' }

--- Отрезок журнала: оба номера включительно, оба необязательны.
local RANGE = { from_id = RECORD_ID, to_id = RECORD_ID }

--- В строке запроса всё — строка, и номера приводятся.
local QUERY = { coerce = true }

--- Отбор узлов на странице «Узлы».
Module.FILTERS = {
    { name = 'all', title = 'все' },
    { name = 'trouble', title = 'с бедой' },
    { name = 'writers', title = 'пишут' },
}

--- Отбор находок по уровню.
Module.LEVELS = {
    { name = 'all', title = 'все' },
    { name = 'critical', title = 'важные' },
    { name = 'warning', title = 'внимание' },
    { name = 'info', title = 'к сведению' },
}

--- Что общего у всех страниц: меню, выбранный раздел, часы.
---@param section string Имя раздела
---@param extra table|nil Что добавить к общему
---@return table
local function page(section, extra)
    local common = {
        sections = Module.SECTIONS,
        section = section,
        format = format,
        now = os.time(),
    }

    for name, value in pairs(extra or {}) do
        common[name] = value
    end

    -- Метка у раздела находок: их число видно из меню, не заходя туда.
    common.issues_count = common.issues ~= nil and #common.issues or nil

    return common
end

---@class TntAdminClusterPage: TntAdminView
---@field by_name table<string, table> Узел по имени: карточка репликасета знает только имена
---@field writers table<string, boolean> Кто пишет: имя узла → да

--- Снимок кластера в виде, пригодном для страницы.
---@param source table
---@return TntAdminClusterPage
local function cluster_of(source)
    local snapshot = source.snapshot ~= nil and source.snapshot() or nil
    local appointments = source.appointments ~= nil and source.appointments() or nil
    local cluster = model.cluster(snapshot, { appointments = appointments }) --[[@as TntAdminClusterPage]]

    -- Узел по имени и признак писателя: карточка репликасета знает имена
    -- своих узлов, а всё остальное о них лежит общим списком.
    cluster.by_name = {}
    cluster.writers = {}

    for _, server in ipairs(cluster.servers or {}) do
        cluster.by_name[server.name] = server
    end

    for _, replicaset in ipairs(cluster.replicasets or {}) do
        for _, name in ipairs(replicaset.writers or {}) do
            cluster.writers[name] = true
        end
    end

    return cluster
end

--- Находки в виде, пригодном для страницы.
---@param source table
---@return table
local function issues_of(source)
    return model.issues(source.issues ~= nil and source.issues() or nil)
end

--- Подсказки в виде, пригодном для страницы.
---@param source table
---@return table
local function suggestions_of(source)
    return model.suggestions(source.suggestions ~= nil and source.suggestions() or nil)
end

--- Подходит ли узел под отбор.
---@param server table
---@param filter string
---@param search string|nil
---@return boolean
function Module.suits(server, filter, search)
    if search ~= nil and search ~= '' then
        local haystack = ('%s %s %s'):format(server.name, server.replicaset or '', server.uri or ''):lower()

        -- Место начала не называется: поиск идёт с первого знака, а число
        -- в строке значило бы, что его можно подвинуть.
        if not haystack:find(search:lower(), nil, true) then
            return false
        end
    end

    if filter == 'trouble' then
        return not server.reachable or server.status ~= 'running'
    end

    if filter == 'writers' then
        return server.writable == true
    end

    return true
end

--- Подсказки, привязанные к узлу: страница показывает их рядом
--- с находкой о том же узле.
---@param suggestions table[]
---@return table<string, table[]>
function Module.advice(suggestions)
    local map = {}

    for _, suggestion in ipairs(suggestions) do
        for _, target in ipairs(suggestion.targets or {}) do
            map[target] = map[target] or {}
            table.insert(map[target], suggestion)
        end
    end

    return map
end

--- Данные страницы обзора.
---@param source table
---@return table
function Module.overview(source)
    local issues = issues_of(source)
    local critical = 0

    for _, issue in ipairs(issues) do
        if issue.level == 'critical' then
            critical = critical + 1
        end
    end

    return page('overview', {
        cluster = cluster_of(source),
        issues = issues,
        critical = critical,
        suggestions = suggestions_of(source),
    })
end

--- Данные страницы узлов.
---@param source table
---@param query table Строка запроса: отбор и поиск
---@return table
function Module.cluster(source, query)
    local cluster = cluster_of(source)
    local filter = query.filter or 'all'
    local search = query.search
    local shown = {}

    for _, server in ipairs(cluster.servers or {}) do
        if Module.suits(server, filter, search) then
            table.insert(shown, server)
        end
    end

    return page('cluster', {
        cluster = cluster,
        servers = shown,
        total = #(cluster.servers or {}),
        filters = Module.FILTERS,
        filter = filter,
        search = search,
    })
end

--- Данные страницы находок.
---@param source table
---@param query table Строка запроса: уровень
---@return table
function Module.issues(source, query)
    local issues = issues_of(source)
    local level = query.level or 'all'
    local shown = {}
    local counts = {}

    for _, issue in ipairs(issues) do
        counts[issue.level] = (counts[issue.level] or 0) + 1

        if level == 'all' or issue.level == level then
            table.insert(shown, issue)
        end
    end

    return page('issues', {
        issues = issues,
        shown = shown,
        counts = counts,
        levels = Module.LEVELS,
        level = level,
        advice = Module.advice(suggestions_of(source)),
    })
end

--- Данные страницы конфигурации.
---@param source table
---@return table
function Module.config(source)
    if source.config == nil then
        return page('config', { missing = 'конфигурация этому узлу недоступна' })
    end

    local config, reason = source.config()

    if config == nil then
        return page('config', { missing = reason or 'конфигурацию прочитать не удалось' })
    end

    return page('config', { config = config })
end

--- Отрезок журнала из строки запроса страницы.
---
--- Пустое поле — не заданное: форма отбора шлёт оба поля всегда,
--- и пустое значит «с начала» или «до конца», а не опечатку.
---@param query table
---@return table range Отрезок числами, а при отказе — как его прислали: форма покажет его для правки
---@return string|nil wrong Почему отрезок не разобран
local function range_of(query)
    local given = {}

    for _, name in ipairs(RANGE_FIELDS) do
        if query[name] ~= '' then
            given[name] = query[name]
        end
    end

    local range, wrong = validate.check(given, RANGE, QUERY)

    if wrong == nil then
        return range
    end

    local said = {}

    for _, name in ipairs(RANGE_FIELDS) do
        if wrong[name] ~= nil then
            table.insert(said, ('%s %s'):format(name, wrong[name]))
        end
    end

    return given, 'отбор записей журнала не разобран: ' .. table.concat(said, '; ')
end

--- Записи одного куска выгрузки: строка — запись.
---@param chunk string
---@return table[]
local function records_of(chunk)
    local records = {}

    for line in tostring(chunk):gmatch('[^\n]+') do
        local ok, record = pcall(json.decode, line)

        -- Оборванная строка в конце куска: показать её нельзя,
        -- а ронять журнал из-за неё — тем более.
        if ok and type(record) == 'table' then
            -- Отметка времени — в микросекундах, и такое число
            -- `json.decode` отдаёт целым int64, а не числом Lua: делится
            -- оно нацело, и дата из него не выходит. Секунды странице
            -- нужны числом, а до 2^53 микросекунд оно точное.
            record.ts = tonumber(record.ts)

            table.insert(records, record)
        end
    end

    return records
end

--- Записи выгрузки по одной.
---
--- Следующий кусок берётся у источника, только когда записи прежнего
--- кончились: в памяти лежит один кусок, а не выгрузка.
---@param produce TntAdminAuditProduce
---@return fun(): table|nil, string|nil read Запись; nil — конец, nil, err — отказ источника
local function reader(produce)
    local records, at = {}, 0

    return function()
        -- Кусок бывает и без единой целой записи: тогда берётся следующий.
        while at == #records do
            local chunk, err = produce()

            if chunk == nil then
                return nil, err
            end

            records, at = records_of(chunk), 0
        end

        at = at + 1

        return records[at]
    end
end

--- Адрес следующей страницы журнала: с первой записи, которая не вошла
--- в эту, до той же границы отрезка.
---@param from_id integer
---@param to_id integer|nil
---@return string
local function next_url(from_id, to_id)
    local url = ('/audit?from_id=%d'):format(from_id)

    if to_id ~= nil then
        url = ('%s&to_id=%d'):format(url, to_id)
    end

    return url
end

---@class TntAdminAuditJournal Записи страницы журнала и то, что о них известно к мигу рисования
---@field records fun(): table|nil Следующая запись страницы; nil — страница кончилась
---@field shown integer Сколько записей страница уже показала
---@field next_url string|nil Адрес следующей страницы: есть, когда журнал за пределом страницы не кончился

--- Записи страницы потоком.
---
--- Шаблон обходит их по мере рисования, и следующий кусок выгрузки
--- читается, когда до него дошла разметка. Чтение идёт на запись
--- вперёд: у последней записи страницы уже известно, есть ли что
--- дальше, и ссылка «дальше» не ведёт на пустую страницу. Число
--- показанных и ссылку шаблон читает после записей — раньше их
--- не знает никто.
---@param first table Первая запись: её прочли до ответа
---@param read fun(): table|nil, string|nil
---@param range table Отрезок, который показывает страница
---@return TntAdminAuditJournal
local function journal_of(first, read, range)
    ---@type table|nil
    local upcoming = first
    ---@type TntAdminAuditJournal
    local journal

    --- Следующая запись страницы; nil — страница кончилась.
    ---@return table|nil
    local function records()
        if upcoming == nil then
            return nil
        end

        if journal.shown == Module.AUDIT_LIMIT then
            journal.next_url = next_url(upcoming.id, range.to_id)

            return nil
        end

        local record = upcoming
        local failure

        upcoming, failure = read()

        -- Отказ источника посреди страницы — бросок. До первого куска
        -- страницы роутер ответит на него обычным отказом 500, после —
        -- оборвёт ответ без завершающего куска: заголовки ушли, и
        -- обрезанная страница не должна выглядеть целой. Слово отказа
        -- уходит в журнал узла записью об обрыве потока.
        if failure ~= nil then
            fail(failure)
        end

        journal.shown = journal.shown + 1

        return record
    end

    journal = { records = records, shown = 0 }

    return journal
end

--- Данные страницы журнала.
---
--- Страница идёт потоком (`view_stream`): записи — не таблица, а перебор
--- кусков выгрузки, и шаблон рисует их по мере чтения. Первую запись
--- страница читает до ответа: пустой журнал видно до таблицы, а отказ
--- источника на первом куске — ещё не обрыв, и страница говорит о нём
--- словами, как об отказе при открытии.
---@param source table
---@param query table Строка запроса: границы отрезка
---@return table
function Module.audit(source, query)
    local range, wrong = range_of(query)

    if wrong ~= nil then
        return page('audit', { range = range, missing = wrong })
    end

    if source.audit == nil then
        return page(
            'audit',
            { range = range, missing = 'журнал аудита этому узлу недоступен' }
        )
    end

    local produce, reason = source.audit(range)

    if produce == nil then
        return page(
            'audit',
            { range = range, missing = reason or 'журнал прочитать не удалось' }
        )
    end

    local read = reader(produce)
    local first, failure = read()

    if failure ~= nil then
        return page('audit', { range = range, missing = failure })
    end

    if first == nil then
        return page('audit', { range = range })
    end

    return page('audit', { range = range, journal = journal_of(first, read, range) })
end

return Module
